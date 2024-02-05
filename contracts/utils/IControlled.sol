// SPDX-License-Identifier: GPL3
pragma solidity ^0.8.0;

interface IControlled {
  function controller() external view returns (address);
  function setController(address controller_) external;
}
