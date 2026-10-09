// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OracleToken} from "../src/OracleToken.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {DeployOracleToken} from "../script/DeployOracleToken.s.sol";

/// @notice A contract that deploys the token, standing in for the launch factory: the supply must
///         land on whichever contract runs `new OracleToken()`, not on the EOA behind it.
contract DeployerProbe {
    function deploy() external returns (OracleToken) {
        return new OracleToken();
    }
}

contract OracleTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal spender = makeAddr("spender");

    OracleToken internal token;

    function setUp() public {
        vm.prank(deployer);
        token = new OracleToken();
    }

    // ------------------------------------------------------------------
    // Metadata and construction
    // ------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "AutonomoUs oracle");
        assertEq(token.symbol(), "ORACLE");
        assertEq(token.decimals(), 18);
    }

    function test_supplyIsOneBillionWithEighteenDecimals() public view {
        assertEq(token.totalSupply(), 1_000_000_000 * 10 ** 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
    }

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_constructorEmitsMintTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), deployer, SUPPLY);
        vm.prank(deployer);
        new OracleToken();
    }

    /// @dev The launch factory is a contract: the supply goes to the contract that deploys, as msg.sender.
    function test_contractDeployerReceivesWholeSupply() public {
        DeployerProbe probe = new DeployerProbe();
        OracleToken deployed = probe.deploy();
        assertEq(deployed.balanceOf(address(probe)), SUPPLY);
        assertEq(deployed.balanceOf(address(this)), 0);
        assertEq(deployed.totalSupply(), SUPPLY);
    }

    function test_deployScriptMintsToTheScriptCaller() public {
        DeployOracleToken script = new DeployOracleToken();
        OracleToken deployed = script.deploy();
        assertEq(deployed.totalSupply(), SUPPLY);
        assertEq(deployed.balanceOf(address(script)), SUPPLY);
    }

    function test_constructorTakesNoArguments() public {
        // Creation code with no appended arguments deploys; the token has no constructor parameters.
        bytes memory code = type(OracleToken).creationCode;
        address at;
        assembly ("memory-safe") {
            at := create(0, add(code, 32), mload(code))
        }
        assertTrue(at != address(0), "plain creation code did not deploy");
        assertEq(OracleToken(at).balanceOf(address(this)), SUPPLY);
    }

    // ------------------------------------------------------------------
    // transfer
    // ------------------------------------------------------------------

    function test_transfer_movesBalanceAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(deployer, alice, 100 ether);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 100 ether));
        assertEq(token.balanceOf(deployer), SUPPLY - 100 ether);
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transfer_wholeBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), SUPPLY);
    }

    function test_transfer_zeroValueSucceeds() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(alice, bob, 0);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transfer_toSelfKeepsBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(deployer, 5 ether));
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_transfer_revertsOnInsufficientBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 10 ether);
        vm.expectRevert(
            abi.encodeWithSelector(OracleToken.ERC20InsufficientBalance.selector, alice, 10 ether, 11 ether)
        );
        vm.prank(alice);
        token.transfer(bob, 11 ether);
        assertEq(token.balanceOf(alice), 10 ether);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transfer_revertsFromEmptyAccount() public {
        vm.expectRevert(abi.encodeWithSelector(OracleToken.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(bob, 1);
    }

    function test_transfer_revertsToZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(OracleToken.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(deployer);
        token.transfer(address(0), 1 ether);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    // ------------------------------------------------------------------
    // approve / allowance / transferFrom
    // ------------------------------------------------------------------

    function test_approve_setsAllowanceAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(deployer, spender, 50 ether);
        vm.prank(deployer);
        assertTrue(token.approve(spender, 50 ether));
        assertEq(token.allowance(deployer, spender), 50 ether);
    }

    function test_approve_overwritesPreviousAllowance() public {
        vm.startPrank(deployer);
        token.approve(spender, 50 ether);
        token.approve(spender, 7 ether);
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), 7 ether);
    }

    function test_approve_revertsForZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(OracleToken.ERC20InvalidSpender.selector, address(0)));
        vm.prank(deployer);
        token.approve(address(0), 1 ether);
    }

    function test_transferFrom_movesAndDecreasesAllowance() public {
        vm.prank(deployer);
        token.approve(spender, 50 ether);

        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(deployer, bob, 20 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, bob, 20 ether));

        assertEq(token.balanceOf(bob), 20 ether);
        assertEq(token.balanceOf(deployer), SUPPLY - 20 ether);
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.allowance(deployer, spender), 30 ether);
    }

    function test_transferFrom_exactAllowanceGoesToZero() public {
        vm.prank(deployer);
        token.approve(spender, 20 ether);
        vm.prank(spender);
        token.transferFrom(deployer, bob, 20 ether);
        assertEq(token.allowance(deployer, spender), 0);
    }

    function test_transferFrom_infiniteAllowanceIsNotDecreased() public {
        vm.prank(deployer);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        token.transferFrom(deployer, bob, 1000 ether);
        assertEq(token.allowance(deployer, spender), type(uint256).max);
        assertEq(token.balanceOf(bob), 1000 ether);
    }

    function test_transferFrom_revertsOnInsufficientAllowance() public {
        vm.prank(deployer);
        token.approve(spender, 5 ether);
        vm.expectRevert(
            abi.encodeWithSelector(OracleToken.ERC20InsufficientAllowance.selector, spender, 5 ether, 6 ether)
        );
        vm.prank(spender);
        token.transferFrom(deployer, bob, 6 ether);
        assertEq(token.allowance(deployer, spender), 5 ether);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferFrom_revertsWithoutAnyAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(OracleToken.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(deployer, bob, 1);
    }

    function test_transferFrom_revertsOnInsufficientBalanceEvenWithAllowance() public {
        vm.prank(deployer);
        token.transfer(alice, 3 ether);
        vm.prank(alice);
        token.approve(spender, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(OracleToken.ERC20InsufficientBalance.selector, alice, 3 ether, 4 ether));
        vm.prank(spender);
        token.transferFrom(alice, bob, 4 ether);
        // A failed pull leaves the allowance untouched.
        assertEq(token.allowance(alice, spender), 10 ether);
    }

    function test_transferFrom_revertsToZeroAddress() public {
        vm.prank(deployer);
        token.approve(spender, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(OracleToken.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(deployer, address(0), 1 ether);
    }

    // ------------------------------------------------------------------
    // Fixed supply and absence of privileged powers
    // ------------------------------------------------------------------

    function test_noMintOrAdminEntryPointExists() public {
        address attacker = makeAddr("attacker");
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            vm.prank(deployer);
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(attacker), 0, signatures[i]);
        }
    }

    function test_noPrivilegedCallMovesOrFreezesAHolder() public {
        vm.prank(deployer);
        token.transfer(alice, 1000 ether);
        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, true));
            assertFalse(ok, signatures[i]);
        }
        // The deployer cannot pull without an allowance either.
        vm.prank(deployer);
        (bool pulled,) = address(token).call(abi.encodeCall(IERC20.transferFrom, (alice, deployer, 1)));
        assertFalse(pulled);
        assertEq(token.balanceOf(alice), 1000 ether);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 500 ether));
        assertEq(token.balanceOf(bob), 500 ether);
    }

    function test_unknownSelectorAndPlainEtherAreRejected() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("doesNotExist()"));
        assertFalse(ok);
        vm.deal(address(this), 1 ether);
        (ok,) = address(token).call{value: 1 wei}("");
        assertFalse(ok);
        assertEq(address(token).balance, 0);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    // ------------------------------------------------------------------
    // Fuzz: conservation of supply
    // ------------------------------------------------------------------

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));
        if (to == deployer) {
            assertEq(token.balanceOf(deployer), SUPPLY);
        } else {
            assertEq(token.balanceOf(to), amount);
            assertEq(token.balanceOf(deployer), SUPPLY - amount);
            assertEq(token.balanceOf(to) + token.balanceOf(deployer), SUPPLY);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferAboveBalanceReverts(uint256 held, uint256 attempt) public {
        held = bound(held, 0, SUPPLY - 1);
        attempt = bound(attempt, held + 1, SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, held);
        vm.expectRevert(abi.encodeWithSelector(OracleToken.ERC20InsufficientBalance.selector, alice, held, attempt));
        vm.prank(alice);
        token.transfer(bob, attempt);
    }

    function testFuzz_transferFromRespectsAllowance(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, SUPPLY);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.approve(spender, allowed);
        vm.prank(spender);
        if (amount > allowed) {
            vm.expectRevert(
                abi.encodeWithSelector(OracleToken.ERC20InsufficientAllowance.selector, spender, allowed, amount)
            );
            token.transferFrom(deployer, bob, amount);
        } else {
            assertTrue(token.transferFrom(deployer, bob, amount));
            assertEq(token.allowance(deployer, spender), allowed - amount);
            assertEq(token.balanceOf(bob), amount);
            assertEq(token.balanceOf(deployer), SUPPLY - amount);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }
}
