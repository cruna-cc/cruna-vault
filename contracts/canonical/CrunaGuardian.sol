// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICrunaGuardian} from "./ICrunaGuardian.sol";
import {IVersioned} from "../utils/IVersioned.sol";
import {FlexiTimelockController} from "../utils/FlexiTimelockController.sol";

/**
 * @title CrunaGuardian
 * @notice Manages a registry of trusted implementations and their required manager versions
 *
 * It is used by
 * - manager and plugins to upgrade its own  implementation
 * - manager to trust a new plugin implementation and allow managed transfers
 */
contract CrunaGuardian is ICrunaGuardian, IVersioned, FlexiTimelockController {
  bool private _allowUntrusted;

  /**
   * @notice Error returned when the arguments are invalid
   */
  error InvalidArguments();

  /**
   * @notice Emitted when a trusted implementation is updated
   */
  mapping(bytes32 nameIdAndImplementationAddress => bool trusted) private _trustedImplementations;

  /**
   * @notice When deployed to production, proposers and executors will be multi-sig wallets owned by the Cruna DAO
   * @param minDelay The minimum delay for timelock operations
   * @param proposers The addresses that can propose timelock operations
   * @param executors The addresses that can execute timelock operations
   * @param admin The address that can admin the contract. It will renounce to the role, as soon as the
   *  DAO is stable and there are no risks in doing so.
   */
  constructor(
    uint256 minDelay,
    address[] memory proposers,
    address[] memory executors,
    address admin
  ) FlexiTimelockController(minDelay, proposers, executors, admin) {}

  /// @dev see {IVersioned-version}
  function version() external pure virtual returns (uint256) {
    // v1.1.0
    return 1_001_000;
  }

  /// @dev see {ICrunaGuardian-setTrustedImplementation}
  function setTrustedImplementation(
    bytes4 nameId,
    address implementation,
    bool trusted
  ) external override onlyThroughTimeController {
    bytes32 _key = bytes32(nameId) | bytes32(uint256(uint160(implementation)));
    if (trusted) {
      _trustedImplementations[_key] = true;
    } else {
      delete _trustedImplementations[_key];
    }
    emit TrustedImplementationUpdated(nameId, implementation, trusted);
  }

  /// @dev see {ICrunaGuardian-trustedImplementation}
  function trustedImplementation(bytes4 nameId, address implementation) external view override returns (bool) {
    return _trustedImplementations[bytes32(nameId) | bytes32(uint256(uint160(implementation)))];
  }

  /// @dev see {ICrunaGuardian-allowUntrusted}
  function allowUntrusted(bool allowUntrusted_) external onlyRoleOrOpenRole(DEFAULT_ADMIN_ROLE) {
    _allowUntrusted = allowUntrusted_;
  }

  /// @dev see {ICrunaGuardian-allowingUntrusted}
  function allowingUntrusted() external view returns (bool) {
    return _allowUntrusted;
  }
}
