// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {OracleToken} from "../src/OracleToken.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

/// @notice Stands in for the launch factory: deploys the token through CREATE2 the way the factory
///         does, holds the supply, and performs the launch's transfers. Only the test drives it.
contract FactoryProbe {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0) && deployed.code.length > 0, "constructor failed");
    }

    function move(IERC20 token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

/// @title OracleTokenEdgeTest
/// @notice The inputs the implementation might not have considered: the owner as its own spender,
///         `from == to` pulls, zero-value pulls without allowance, the boundary of the unlimited
///         allowance, two spenders racing for one balance, the exact ABI return shape, and the launch
///         flows at their exact amounts. Builds on `OracleToken.t.sol`; nothing here repeats it.
/// forge-config: default.fuzz.runs = 1000
contract OracleTokenEdgeTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    bytes32 internal constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    bytes32 internal constant APPROVAL_TOPIC = keccak256("Approval(address,address,uint256)");

    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal spender = makeAddr("spender");
    address internal otherSpender = makeAddr("otherSpender");

    OracleToken internal token;

    function setUp() public {
        vm.prank(deployer);
        token = new OracleToken();
    }

    // ------------------------------------------------------------------
    // transferFrom: the caller the code did not assume
    // ------------------------------------------------------------------

    /// @dev The owner is not a privileged spender of its own balance: without a self-allowance,
    ///      pulling its own tokens reverts like any other spender's would.
    function test_transferFrom_ownerNeedsSelfAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(OracleToken.ERC20InsufficientAllowance.selector, deployer, 0, 1 ether));
        vm.prank(deployer);
        token.transferFrom(deployer, alice, 1 ether);

        vm.startPrank(deployer);
        token.approve(deployer, 1 ether);
        assertTrue(token.transferFrom(deployer, alice, 1 ether));
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 1 ether);
        assertEq(token.allowance(deployer, deployer), 0);
    }

    /// @dev `from == to`: the balance is unchanged but the allowance is still consumed.
    function test_transferFrom_sameFromAndTo_consumesAllowanceOnly() public {
        vm.prank(deployer);
        token.approve(spender, 10 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, deployer, 4 ether));
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.allowance(deployer, spender), 6 ether);
    }

    /// @dev A zero-value pull needs no allowance and leaves a zero allowance at zero.
    function test_transferFrom_zeroValueWithoutAllowanceSucceeds() public {
        assertEq(token.allowance(deployer, spender), 0);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(deployer, bob, 0);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, bob, 0));
        assertEq(token.allowance(deployer, spender), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    /// @dev Exactly `type(uint256).max` is unlimited; one less is finite and is decreased.
    function test_transferFrom_maxMinusOneIsFinite() public {
        vm.prank(deployer);
        token.approve(spender, type(uint256).max - 1);
        vm.prank(spender);
        token.transferFrom(deployer, bob, 1 ether);
        assertEq(token.allowance(deployer, spender), type(uint256).max - 1 - 1 ether);
    }

    /// @dev The unlimited allowance survives spending the whole supply and a zero-value pull.
    function test_transferFrom_unlimitedSurvivesWholeSupplyAndZero() public {
        vm.prank(deployer);
        token.approve(spender, type(uint256).max);
        vm.startPrank(spender);
        token.transferFrom(deployer, bob, 0);
        token.transferFrom(deployer, bob, SUPPLY);
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), type(uint256).max);
        assertEq(token.balanceOf(bob), SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
        // The allowance is unlimited, but the balance is not.
        vm.expectRevert(abi.encodeWithSelector(OracleToken.ERC20InsufficientBalance.selector, deployer, 0, 1));
        vm.prank(spender);
        token.transferFrom(deployer, bob, 1);
    }

    /// @dev `transferFrom` emits exactly one `Transfer` and no `Approval` on the decrease.
    function test_transferFrom_emitsNoApprovalEvent() public {
        vm.prank(deployer);
        token.approve(spender, 10 ether);
        vm.recordLogs();
        vm.prank(spender);
        token.transferFrom(deployer, bob, 3 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 transfers;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(token)) continue;
            assertTrue(logs[i].topics[0] != APPROVAL_TOPIC, "transferFrom emitted Approval");
            if (logs[i].topics[0] == TRANSFER_TOPIC) transfers++;
        }
        assertEq(transfers, 1);
        assertEq(token.allowance(deployer, spender), 7 ether);
    }

    /// @dev An allowance is per (owner, spender): it never lets the spender pull from someone else.
    function test_transferFrom_allowanceDoesNotCrossOwners() public {
        vm.prank(deployer);
        token.transfer(alice, 10 ether);
        vm.prank(deployer);
        token.approve(spender, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(OracleToken.ERC20InsufficientAllowance.selector, spender, 0, 1 ether));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1 ether);
        assertEq(token.allowance(deployer, spender), 10 ether);
        assertEq(token.balanceOf(alice), 10 ether);
    }

    /// @dev Two spenders each allowed the full balance: the first takes it all, the second finds an
    ///      intact allowance but an empty balance.
    function test_transferFrom_twoSpendersOneBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 10 ether);
        vm.startPrank(alice);
        token.approve(spender, 10 ether);
        token.approve(otherSpender, 10 ether);
        vm.stopPrank();

        vm.prank(spender);
        token.transferFrom(alice, bob, 10 ether);
        assertEq(token.balanceOf(alice), 0);

        vm.expectRevert(abi.encodeWithSelector(OracleToken.ERC20InsufficientBalance.selector, alice, 0, 10 ether));
        vm.prank(otherSpender);
        token.transferFrom(alice, bob, 10 ether);
        assertEq(token.allowance(alice, otherSpender), 10 ether);
        assertEq(token.balanceOf(bob), 10 ether);
    }

    // ------------------------------------------------------------------
    // approve: edges
    // ------------------------------------------------------------------

    function test_approve_zeroClearsAndEmits() public {
        vm.startPrank(deployer);
        token.approve(spender, 5 ether);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(deployer, spender, 0);
        assertTrue(token.approve(spender, 0));
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), 0);
        vm.expectRevert(abi.encodeWithSelector(OracleToken.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(deployer, bob, 1);
    }

    /// @dev Allowances are independent of balances: an empty account may approve anything, and
    ///      the approval does not conjure a balance.
    function test_approve_fromEmptyAccountIsAllowedButUnspendable() public {
        vm.prank(alice);
        assertTrue(token.approve(spender, SUPPLY));
        assertEq(token.allowance(alice, spender), SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(OracleToken.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);
    }

    function test_approve_zeroSpenderRevertsEvenForZeroValue() public {
        vm.expectRevert(abi.encodeWithSelector(OracleToken.ERC20InvalidSpender.selector, address(0)));
        vm.prank(deployer);
        token.approve(address(0), 0);
        assertEq(token.allowance(deployer, address(0)), 0);
    }

    // ------------------------------------------------------------------
    // transfer: edges
    // ------------------------------------------------------------------

    /// @dev The same call twice: the second whole-balance transfer has nothing left to move.
    function test_transfer_wholeBalanceTwiceRevertsTheSecondTime() public {
        vm.startPrank(deployer);
        token.transfer(alice, SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(OracleToken.ERC20InsufficientBalance.selector, deployer, 0, SUPPLY));
        token.transfer(alice, SUPPLY);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), SUPPLY);
    }

    function test_transfer_oneWeiAndSupplyMinusOneWei() public {
        vm.startPrank(deployer);
        token.transfer(alice, 1);
        token.transfer(bob, SUPPLY - 1);
        vm.stopPrank();
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(bob), SUPPLY - 1);
        assertEq(token.balanceOf(alice) + token.balanceOf(bob), SUPPLY);
    }

    /// @dev A whole-balance self-transfer: the unchecked subtraction then addition must land back
    ///      on the same value, not on zero.
    function test_transfer_wholeBalanceToSelfKeepsBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(deployer, SUPPLY));
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    /// @dev Sending to the token contract succeeds and the tokens are stuck: nothing can move them
    ///      (the contract never calls itself and there is no rescue). Documented in the README.
    function test_transfer_toTokenContractIsAcceptedAndStuck() public {
        vm.prank(deployer);
        assertTrue(token.transfer(address(token), 1 ether));
        assertEq(token.balanceOf(address(token)), 1 ether);
        assertEq(token.totalSupply(), SUPPLY);
        // No entry point lets anyone pull them: an allowance from the token was never granted.
        vm.expectRevert(abi.encodeWithSelector(OracleToken.ERC20InsufficientAllowance.selector, deployer, 0, 1 ether));
        vm.prank(deployer);
        token.transferFrom(address(token), deployer, 1 ether);
    }

    /// @dev Transfers from an account that never existed before: balanceOf defaults to zero and the
    ///      error reports that zero, not garbage.
    function test_transfer_fromNeverSeenAddressReportsZeroBalance() public {
        address ghost = address(uint160(uint256(keccak256("never seen"))));
        vm.expectRevert(abi.encodeWithSelector(OracleToken.ERC20InsufficientBalance.selector, ghost, 0, 1));
        vm.prank(ghost);
        token.transfer(alice, 1);
        assertEq(token.balanceOf(ghost), 0);
    }

    // ------------------------------------------------------------------
    // ABI surface integrators depend on
    // ------------------------------------------------------------------

    /// @dev Return data is exactly one word holding `true`: integrators that check both "returned
    ///      nothing" and "returned true" must land on the second path.
    function test_abi_transferAndApproveReturnOneTrueWord() public {
        vm.prank(deployer);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.transfer, (alice, 1)));
        assertTrue(ok);
        assertEq(ret.length, 32);
        assertEq(abi.decode(ret, (bool)), true);

        vm.prank(deployer);
        (ok, ret) = address(token).call(abi.encodeCall(IERC20.approve, (spender, 1)));
        assertTrue(ok);
        assertEq(ret.length, 32);
        assertEq(abi.decode(ret, (bool)), true);

        vm.prank(spender);
        (ok, ret) = address(token).call(abi.encodeCall(IERC20.transferFrom, (deployer, alice, 1)));
        assertTrue(ok);
        assertEq(ret.length, 32);
        assertEq(abi.decode(ret, (bool)), true);
    }

    /// @dev The metadata is reachable through `staticcall` (pure/view), as explorers read it.
    function test_abi_metadataIsReadableByStaticcall() public view {
        (bool ok, bytes memory ret) = address(token).staticcall(abi.encodeCall(IERC20.name, ()));
        assertTrue(ok);
        assertEq(abi.decode(ret, (string)), "AutonomoUs oracle");
        (ok, ret) = address(token).staticcall(abi.encodeCall(IERC20.symbol, ()));
        assertTrue(ok);
        assertEq(abi.decode(ret, (string)), "ORACLE");
        (ok, ret) = address(token).staticcall(abi.encodeCall(IERC20.decimals, ()));
        assertTrue(ok);
        assertEq(abi.decode(ret, (uint8)), 18);
        (ok, ret) = address(token).staticcall(abi.encodeCall(IERC20.totalSupply, ()));
        assertTrue(ok);
        assertEq(abi.decode(ret, (uint256)), SUPPLY);
    }

    /// @dev Calldata shorter than the ABI expects reverts rather than decoding zeros.
    function test_abi_shortCalldataReverts() public {
        vm.prank(deployer);
        (bool ok,) = address(token).call(abi.encodePacked(IERC20.transfer.selector, alice));
        assertFalse(ok);
        assertEq(token.balanceOf(alice), 0);
    }

    /// @dev Only the constructor ever emits a `Transfer` from the zero address: that mint shows up
    ///      once, and never again from `transfer`.
    function test_events_mintTransferEmittedExactlyOnceAtConstruction() public {
        vm.recordLogs();
        vm.prank(deployer);
        OracleToken fresh = new OracleToken();
        vm.prank(deployer);
        fresh.transfer(alice, 1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 mints;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(fresh) || logs[i].topics[0] != TRANSFER_TOPIC) continue;
            if (logs[i].topics[1] == bytes32(0)) {
                mints++;
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(deployer))));
                assertEq(abi.decode(logs[i].data, (uint256)), SUPPLY);
            }
        }
        assertEq(mints, 1);
    }

    // ------------------------------------------------------------------
    // Launch flows at their exact amounts
    // ------------------------------------------------------------------

    /// @dev The factory deploys through CREATE2 and receives the whole supply as msg.sender.
    function test_launch_create2DeploymentMintsToTheFactory() public {
        FactoryProbe factory = new FactoryProbe();
        bytes memory code = type(OracleToken).creationCode;
        bytes32 salt = bytes32(uint256(42));
        address predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(code)))))
        );
        address deployed = factory.deploy(code, salt);
        assertEq(deployed, predicted);
        OracleToken launched = OracleToken(deployed);
        assertEq(launched.totalSupply(), SUPPLY);
        assertEq(launched.balanceOf(address(factory)), SUPPLY);
        assertEq(launched.balanceOf(address(this)), 0);
        assertEq(launched.balanceOf(deployer), 0);
    }

    /// @dev 10% to the distributor, 80% to the pool, 10% to the requester, then the distributor's
    ///      claims: every flow arrives whole and the supply is unchanged. A fee or burn on any path
    ///      would short the last claimant.
    function test_launch_flowsMoveExactlyWhatTheySay() public {
        FactoryProbe factory = new FactoryProbe();
        OracleToken launched = OracleToken(factory.deploy(type(OracleToken).creationCode, bytes32(uint256(1))));
        address distributor = makeAddr("distributor");
        address pool = makeAddr("poolManager");
        address requester = makeAddr("requester");
        address claimantA = makeAddr("claimantA");
        address claimantB = makeAddr("claimantB");

        uint256 swarm = SUPPLY * 1000 / 10_000;
        uint256 poolShare = SUPPLY * 8000 / 10_000;
        uint256 remainder = SUPPLY - swarm - poolShare;

        assertTrue(factory.move(launched, distributor, swarm));
        assertTrue(factory.move(launched, pool, poolShare));
        assertTrue(factory.move(launched, requester, remainder));
        assertEq(launched.balanceOf(address(factory)), 0, "the factory kept something back");
        assertEq(launched.balanceOf(distributor), swarm);
        assertEq(launched.balanceOf(pool), poolShare);
        assertEq(launched.balanceOf(requester), remainder);

        // Claims: the distributor empties exactly.
        vm.startPrank(distributor);
        assertTrue(launched.transfer(claimantA, swarm / 3));
        assertTrue(launched.transfer(claimantB, swarm - swarm / 3));
        vm.stopPrank();
        assertEq(launched.balanceOf(distributor), 0, "the distributor kept something back");
        assertEq(launched.balanceOf(claimantA) + launched.balanceOf(claimantB), swarm);

        // A trader buys from and sells back into the pool: exact both ways.
        address trader = makeAddr("trader");
        vm.prank(pool);
        launched.transfer(trader, 123_456_789);
        assertEq(launched.balanceOf(trader), 123_456_789);
        vm.prank(trader);
        launched.transfer(pool, 123_456_789);
        assertEq(launched.balanceOf(trader), 0);
        assertEq(launched.balanceOf(pool), poolShare);

        assertEq(launched.totalSupply(), SUPPLY, "the launch flows changed the supply");
    }

    /// @dev The factory cannot do anything to the supply after the launch: it is an ordinary holder
    ///      once it has forwarded everything.
    function test_launch_factoryHasNoPowerAfterForwarding() public {
        FactoryProbe factory = new FactoryProbe();
        OracleToken launched = OracleToken(factory.deploy(type(OracleToken).creationCode, bytes32(0)));
        address holder = makeAddr("holder");
        factory.move(launched, holder, SUPPLY);
        assertEq(launched.balanceOf(address(factory)), 0);
        vm.expectRevert(abi.encodeWithSelector(OracleToken.ERC20InsufficientBalance.selector, address(factory), 0, 1));
        factory.move(launched, holder, 1);
        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(OracleToken.ERC20InsufficientAllowance.selector, address(factory), 0, 1));
        launched.transferFrom(holder, address(factory), 1);
        assertEq(launched.balanceOf(holder), SUPPLY);
    }

    // ------------------------------------------------------------------
    // Property tests
    // ------------------------------------------------------------------

    /// @dev Round trip: A→B→C→A returns exactly what left; there is no fee on any hop.
    function testFuzz_roundTripThroughThreeHoldersIsExact(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, amount);
        vm.prank(alice);
        token.transfer(bob, amount);
        vm.prank(bob);
        token.transfer(deployer, amount);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    /// @dev Any owner may approve any non-zero spender any value, and the allowance is exactly
    ///      that value regardless of the owner's balance.
    function testFuzz_approveSetsExactly(address owner, address who, uint256 value) public {
        if (who == address(0)) who = address(1);
        owner = _usableSender(owner, alice);
        vm.prank(owner);
        assertTrue(token.approve(who, value));
        assertEq(token.allowance(owner, who), value);
        // And is independent of the reverse direction.
        if (owner != who) assertEq(token.allowance(who, owner), 0);
    }

    /// @dev Splitting a transfer into two parts is the same as one transfer: no rounding, no fee.
    function testFuzz_transferIsAdditive(uint256 total, uint256 first) public {
        total = bound(total, 0, SUPPLY);
        first = bound(first, 0, total);
        vm.startPrank(deployer);
        token.transfer(alice, first);
        token.transfer(alice, total - first);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), total);
        assertEq(token.balanceOf(deployer), SUPPLY - total);
    }

    /// @dev A finite allowance decreases by exactly the sum of what was pulled, across many pulls.
    function testFuzz_allowanceDecreasesBySumOfPulls(uint256 allowed, uint256 a, uint256 b, uint256 c) public {
        allowed = bound(allowed, 0, SUPPLY);
        a = bound(a, 0, allowed);
        b = bound(b, 0, allowed - a);
        c = bound(c, 0, allowed - a - b);
        vm.prank(deployer);
        token.approve(spender, allowed);
        vm.startPrank(spender);
        token.transferFrom(deployer, bob, a);
        token.transferFrom(deployer, bob, b);
        token.transferFrom(deployer, bob, c);
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), allowed - a - b - c);
        assertEq(token.balanceOf(bob), a + b + c);
    }

    /// @dev The insufficient-balance error carries the exact balance and request, for any holder.
    function testFuzz_insufficientBalanceErrorIsExact(address holder, uint256 held, uint256 attempt) public {
        holder = _usableSender(holder, alice);
        if (holder == deployer) holder = alice;
        held = bound(held, 0, SUPPLY - 1);
        attempt = bound(attempt, held + 1, type(uint256).max);
        vm.prank(deployer);
        token.transfer(holder, held);
        vm.expectRevert(abi.encodeWithSelector(OracleToken.ERC20InsufficientBalance.selector, holder, held, attempt));
        vm.prank(holder);
        token.transfer(bob, attempt);
        assertEq(token.balanceOf(holder), held);
    }

    /// @dev Two deployments are independent: each mints its own supply to its own deployer and
    ///      neither can see the other's balances.
    function testFuzz_deploymentsAreIndependent(address other) public {
        other = _usableSender(other, bob);
        vm.prank(other);
        OracleToken second = new OracleToken();
        assertEq(second.balanceOf(other), SUPPLY);
        assertEq(second.balanceOf(deployer), other == deployer ? SUPPLY : 0);
        assertEq(token.balanceOf(other), other == deployer ? SUPPLY : 0);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(second.totalSupply(), SUPPLY);
    }

    /// @dev Keeps a fuzzed sender off the addresses forge reserves (the zero address, the cheatcode
    ///      and console addresses, and the precompiles), which cannot meaningfully send a transaction.
    function _usableSender(address candidate, address fallbackTo) internal view returns (address) {
        if (
            uint160(candidate) <= 0xff || candidate == address(vm) || candidate == CONSOLE
                || candidate == DEFAULT_SENDER
        ) {
            return fallbackTo;
        }
        return candidate;
    }
}
