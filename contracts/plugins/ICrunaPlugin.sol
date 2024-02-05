// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.9;

import {IBoundContractExtended} from "../utils/IBoundContractExtended.sol";
import {ICrunaRegistry} from "../utils/CrunaRegistry.sol";
import {ICrunaGuardian} from "../utils/ICrunaGuardian.sol";

import {IVault} from "../token/IVault.sol";

/**
 @title ICrunaPlugin.sol
 @dev Interface for plugins
   Technically, plugins are secondary managers, pluggable in
   the primary manage, which is CrunaManager.sol.sol
*/
interface ICrunaPlugin is IBoundContractExtended {
  // this is also used in the CrunaManager
  struct CrunaPlugin {
    address proxyAddress;
    bool canManageTransfer;
    bool canBeReset;
    bool active;
  }

  function init() external;

  // function called in the dashboard to know if the plugin is asking the
  // right to make a managed transfer of the vault
  function requiresToManageTransfer() external pure returns (bool);

  function requiresResetOnTransfer() external pure returns (bool);

  // Reset the plugin to the factory settings
  function reset() external;

  function nameId() external view returns (bytes4);

  function guardian() external view returns (ICrunaGuardian);

  function registry() external view returns (ICrunaRegistry);

  function emitter() external view returns (address);

  function vault() external view returns (IVault);

  function combineBytes4(bytes4 a, bytes4 b) external pure returns (bytes32);

  // @dev Upgrade the implementation of the manager/plugin
  //   Notice that the owner can upgrade active or disable plugins
  //   so that, if a plugin is compromised, the user can disable it,
  //   wait for a new trusted implementation and upgrade it.
  function upgrade(address implementation_) external;

  function getImplementation() external view returns (address);
}
