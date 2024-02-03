// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ERC6551AccountProxy} from "../../utils/ERC6551AccountProxy.sol";

contract InheritanceCrunaPluginProxy is ERC6551AccountProxy {
  constructor(address _initialImplementation, address _deployer) ERC6551AccountProxy(_initialImplementation, _deployer) {}
}