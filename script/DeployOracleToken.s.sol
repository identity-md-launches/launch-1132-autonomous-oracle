// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {OracleToken} from "../src/OracleToken.sol";

/// @title DeployOracleToken
/// @notice Deploys `OracleToken` on its own, for a standalone deployment or a local check.
/// @dev The IdentityMD launch does not use this script: the factory deploys the token from its
///      creation code through CREATE2 and receives the supply as `msg.sender`. The script exists so
///      that an independent deployment is reviewable and so that tests can exercise the deploy
///      path directly through `deploy()`. The token takes no constructor arguments, so there is no
///      configuration to read: `run()` reads nothing from the environment.
contract DeployOracleToken is Script {
    /// @notice Broadcast entry point. The broadcasting account becomes the deployer and receives the
    ///         whole supply.
    function run() external returns (OracleToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }

    /// @notice Deploys the token. Whoever is `msg.sender` of the `new` receives the whole supply.
    /// @dev Pure deployment logic, callable from tests without broadcasting.
    function deploy() public returns (OracleToken token) {
        token = new OracleToken();
    }
}
