// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {OracleToken} from "../src/OracleToken.sol";

/// @title OracleTokenHandler
/// @notice Drives the token with random call sequences from several actors and keeps ghost
///         accounting of what the token should hold, so the invariants can compare the token's
///         state with an independent record rather than with itself.
/// @dev Every entry point bounds its inputs so that the call it makes is expected to succeed, and
///      the dedicated failure-path entry points expect the exact revert and assert that nothing
///      moved. The suite runs with `fail-on-revert`, so a revert the handler did not plan for is a
///      failure, not a discarded run.
contract OracleTokenHandler is CommonBase, StdCheats, StdUtils {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    OracleToken public immutable token;
    address public immutable deployer;

    /// @dev Fixed actors: the deployer and four ordinary holders, who send, approve and spend.
    ///      Recipients are the actors plus the token contract itself, which can receive but never
    ///      sends (a contract does not call itself, and there is no rescue path). Random recipients
    ///      are added to `holders` as they are touched, so the sum invariant always covers every
    ///      address that can hold a balance.
    address[] public actors;
    address[] public recipients;
    address[] public holders;
    mapping(address => bool) public isHolder;

    // Ghost accounting, maintained alongside every successful call.
    mapping(address => uint256) public ghost_balance;
    mapping(address => mapping(address => uint256)) public ghost_allowance;
    mapping(address => uint256) public ghost_inflow;
    mapping(address => uint256) public ghost_outflow;
    uint256 public ghost_transferredTotal;
    uint256 public ghost_sumChecks;

    // Call accounting, so a vacuous run is visible.
    uint256 public calls_transfer;
    uint256 public calls_transferFrom;
    uint256 public calls_approve;
    uint256 public calls_transferToRandom;
    uint256 public calls_revertInsufficientBalance;
    uint256 public calls_revertInsufficientAllowance;
    uint256 public calls_revertZeroReceiver;
    uint256 public calls_revertZeroSpender;

    constructor(OracleToken token_, address deployer_) {
        token = token_;
        deployer = deployer_;
        actors.push(deployer_);
        actors.push(makeAddr("actor-alice"));
        actors.push(makeAddr("actor-bob"));
        actors.push(makeAddr("actor-carol"));
        actors.push(makeAddr("actor-dave"));
        for (uint256 i = 0; i < actors.length; i++) {
            recipients.push(actors[i]);
        }
        recipients.push(address(token_));
        for (uint256 i = 0; i < recipients.length; i++) {
            _track(recipients[i]);
        }
        ghost_balance[deployer_] = SUPPLY;
        ghost_inflow[deployer_] = SUPPLY;
    }

    // ------------------------------------------------------------------
    // Happy paths with bounded inputs
    // ------------------------------------------------------------------

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _recipient(toSeed);
        amount = bound(amount, 0, ghost_balance[from]);

        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(from);
        bool ok = token.transfer(to, amount);
        require(ok, "transfer returned false");

        _recordMove(from, to, amount);
        _postMove(from, to, amount, fromBefore, toBefore);
        calls_transfer++;
    }

    /// @dev Sends to an arbitrary non-zero address, which is then tracked as a holder. This is the
    ///      only way an address outside the actor set gains a balance, so the sum invariant stays
    ///      complete.
    function transferToRandom(uint256 fromSeed, address to, uint256 amount) external {
        if (to == address(0)) to = address(1);
        address from = _actor(fromSeed);
        amount = bound(amount, 0, ghost_balance[from]);

        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(from);
        require(token.transfer(to, amount), "transfer returned false");

        _track(to);
        _recordMove(from, to, amount);
        _postMove(from, to, amount, fromBefore, toBefore);
        calls_transferToRandom++;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool unlimited) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        if (unlimited) amount = type(uint256).max;

        vm.prank(owner);
        require(token.approve(spender, amount), "approve returned false");

        ghost_allowance[owner][spender] = amount;
        require(token.allowance(owner, spender) == amount, "approve did not set the allowance outright");
        calls_approve++;
    }

    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _recipient(toSeed);
        uint256 allowed = ghost_allowance[from][spender];
        uint256 cap = allowed < ghost_balance[from] ? allowed : ghost_balance[from];
        amount = bound(amount, 0, cap);

        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        uint256 spenderBefore = token.balanceOf(spender);

        vm.prank(spender);
        require(token.transferFrom(from, to, amount), "transferFrom returned false");

        if (allowed != type(uint256).max) {
            ghost_allowance[from][spender] = allowed - amount;
        }
        require(token.allowance(from, spender) == ghost_allowance[from][spender], "allowance after transferFrom");
        if (spender != from && spender != to) {
            require(token.balanceOf(spender) == spenderBefore, "spender's own balance moved");
        }
        _recordMove(from, to, amount);
        _postMove(from, to, amount, fromBefore, toBefore);
        calls_transferFrom++;
    }

    // ------------------------------------------------------------------
    // Failure paths: the exact revert, and nothing moves
    // ------------------------------------------------------------------

    function transferAboveBalance(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _recipient(toSeed);
        uint256 held = ghost_balance[from];
        excess = bound(excess, 1, type(uint256).max - held);
        uint256 attempt = held + excess;

        vm.expectRevert(abi.encodeWithSelector(OracleToken.ERC20InsufficientBalance.selector, from, held, attempt));
        vm.prank(from);
        token.transfer(to, attempt);

        require(token.balanceOf(from) == held, "a reverted transfer moved the sender's balance");
        calls_revertInsufficientBalance++;
    }

    function transferFromAboveAllowance(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 excess)
        external
    {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _recipient(toSeed);
        uint256 allowed = ghost_allowance[from][spender];
        if (allowed == type(uint256).max) {
            // Unlimited cannot be exceeded; reset it to a finite value first so the path is reachable.
            vm.prank(from);
            token.approve(spender, 0);
            ghost_allowance[from][spender] = 0;
            allowed = 0;
        }
        excess = bound(excess, 1, type(uint256).max - allowed);
        uint256 attempt = allowed + excess;

        vm.expectRevert(
            abi.encodeWithSelector(OracleToken.ERC20InsufficientAllowance.selector, spender, allowed, attempt)
        );
        vm.prank(spender);
        token.transferFrom(from, to, attempt);

        require(token.allowance(from, spender) == allowed, "a reverted transferFrom changed the allowance");
        require(token.balanceOf(from) == ghost_balance[from], "a reverted transferFrom moved the balance");
        calls_revertInsufficientAllowance++;
    }

    function transferToZeroAddress(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, ghost_balance[from]);

        vm.expectRevert(abi.encodeWithSelector(OracleToken.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(from);
        token.transfer(address(0), amount);

        require(token.balanceOf(from) == ghost_balance[from], "a reverted transfer moved the sender's balance");
        calls_revertZeroReceiver++;
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);

        vm.expectRevert(abi.encodeWithSelector(OracleToken.ERC20InvalidSpender.selector, address(0)));
        vm.prank(owner);
        token.approve(address(0), amount);

        require(token.allowance(owner, address(0)) == 0, "the zero spender gained an allowance");
        calls_revertZeroSpender++;
    }

    // ------------------------------------------------------------------
    // Views for the invariants
    // ------------------------------------------------------------------

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    function sumOfTrackedBalances() external view returns (uint256 sum) {
        for (uint256 i = 0; i < holders.length; i++) {
            sum += token.balanceOf(holders[i]);
        }
    }

    function sumOfGhostBalances() external view returns (uint256 sum) {
        for (uint256 i = 0; i < holders.length; i++) {
            sum += ghost_balance[holders[i]];
        }
    }

    function totalCalls() external view returns (uint256) {
        return calls_transfer + calls_transferFrom + calls_approve + calls_transferToRandom
            + calls_revertInsufficientBalance + calls_revertInsufficientAllowance + calls_revertZeroReceiver
            + calls_revertZeroSpender;
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    function _recipient(uint256 seed) internal view returns (address) {
        return recipients[bound(seed, 0, recipients.length - 1)];
    }

    function _track(address account) internal {
        if (!isHolder[account]) {
            isHolder[account] = true;
            holders.push(account);
        }
    }

    function _recordMove(address from, address to, uint256 amount) internal {
        ghost_balance[from] -= amount;
        ghost_balance[to] += amount;
        ghost_outflow[from] += amount;
        ghost_inflow[to] += amount;
        ghost_transferredTotal += amount;
    }

    /// @dev Per-call postconditions (assertion mode): the exact amount moved, and a self-transfer
    ///      changed nothing.
    function _postMove(address from, address to, uint256 amount, uint256 fromBefore, uint256 toBefore) internal {
        if (from == to) {
            require(token.balanceOf(from) == fromBefore, "self-transfer changed the balance");
        } else {
            require(token.balanceOf(from) == fromBefore - amount, "sender did not lose exactly the amount");
            require(token.balanceOf(to) == toBefore + amount, "recipient did not gain exactly the amount");
        }
        ghost_sumChecks++;
    }
}

/// @title OracleTokenInvariantTest
/// @notice Properties that must hold after every random call sequence the handler drives.
/// @dev Run counts are set here because foundry.toml is not this suite's to change.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract OracleTokenInvariantTest is StdInvariant, Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    OracleToken internal token;
    OracleTokenHandler internal handler;
    address internal deployer = makeAddr("deployer");

    function setUp() public {
        vm.prank(deployer);
        token = new OracleToken();
        handler = new OracleTokenHandler(token, deployer);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = OracleTokenHandler.transfer.selector;
        selectors[1] = OracleTokenHandler.transferToRandom.selector;
        selectors[2] = OracleTokenHandler.approve.selector;
        selectors[3] = OracleTokenHandler.transferFrom.selector;
        selectors[4] = OracleTokenHandler.transferAboveBalance.selector;
        selectors[5] = OracleTokenHandler.transferFromAboveAllowance.selector;
        selectors[6] = OracleTokenHandler.transferToZeroAddress.selector;
        selectors[7] = OracleTokenHandler.approveZeroSpender.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev T-01 / conservation: what the token reports as supply never changes, and it equals the
    ///      sum of every balance that any call sequence could have created.
    function invariant_totalSupplyIsConstant() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
    }

    function invariant_sumOfBalancesEqualsTotalSupply() public view {
        assertEq(handler.sumOfTrackedBalances(), SUPPLY, "sum of balances drifted from the supply");
    }

    /// @dev Internal accounting = external reality: every tracked balance equals the ghost record.
    function invariant_balancesMatchGhostRecord() public view {
        uint256 n = handler.holderCount();
        for (uint256 i = 0; i < n; i++) {
            address holder = handler.holders(i);
            assertEq(token.balanceOf(holder), handler.ghost_balance(holder), "balance disagrees with ghost");
            assertEq(
                token.balanceOf(holder),
                handler.ghost_inflow(holder) - handler.ghost_outflow(holder),
                "balance disagrees with inflow minus outflow"
            );
        }
        assertEq(handler.sumOfGhostBalances(), SUPPLY);
    }

    /// @dev Nobody ever holds more than exists.
    function invariant_noBalanceExceedsSupply() public view {
        uint256 n = handler.holderCount();
        for (uint256 i = 0; i < n; i++) {
            assertLe(token.balanceOf(handler.holders(i)), SUPPLY);
        }
    }

    /// @dev T-06: there is no burn path, so the zero address never accumulates anything.
    function invariant_zeroAddressHoldsNothing() public view {
        assertEq(token.balanceOf(address(0)), 0);
    }

    /// @dev Allowances only change through `approve` (set outright) and a finite `transferFrom`
    ///      (decreased by the amount); the unlimited allowance is never decreased.
    function invariant_allowancesMatchGhostRecord() public view {
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = 0; j < n; j++) {
                address owner = handler.actors(i);
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.ghost_allowance(owner, spender), "allowance drift");
            }
        }
    }

    /// @dev The token never holds ether: it has no receive or fallback.
    function invariant_tokenHoldsNoEther() public view {
        assertEq(address(token).balance, 0);
    }

    /// @dev Tokens sent to the token contract itself are stuck: there is no rescue path, so that
    ///      balance only ever grows and equals everything that was ever sent there.
    function invariant_tokensSentToTheContractNeverLeave() public view {
        assertEq(handler.ghost_outflow(address(token)), 0);
        assertEq(token.balanceOf(address(token)), handler.ghost_inflow(address(token)));
    }

    /// @dev Guards against a vacuous run. Invariants are also checked before the first call, so this
    ///      lives in the hook that runs once each sequence has finished.
    function afterInvariant() public view {
        assertGt(handler.totalCalls(), 0, "no handler call ran");
        assertEq(
            handler.totalCalls(),
            handler.ghost_sumChecks() + handler.calls_approve() + handler.calls_revertInsufficientBalance()
                + handler.calls_revertInsufficientAllowance() + handler.calls_revertZeroReceiver()
                + handler.calls_revertZeroSpender()
        );
    }
}
