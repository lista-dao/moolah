// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Id } from "./IMoolah.sol";

interface IProvider {
    function liquidate(Id id, address borrower) external;
}
