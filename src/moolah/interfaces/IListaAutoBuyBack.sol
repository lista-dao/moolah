// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface IListaAutoBuyBack {
  function setTokenWhitelist(address token, bool status) external;
  function tokenWhitelist(address token) external view returns (bool);
}
