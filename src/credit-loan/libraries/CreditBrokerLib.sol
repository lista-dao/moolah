// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { FixedTermAndRate } from "../interfaces/ICreditBroker.sol";

library CreditBrokerLib {
  uint256 public constant MAX_FIXED_TERM_APR = 9e27; // 8 * RATE_SCALE = 800% MAX APR

  event FixedTermAndRateUpdated(uint256 termId, uint256 duration, uint256 apr);

  function updateFixedTermAndRate(
    FixedTermAndRate[] storage fixedTerms,
    FixedTermAndRate calldata term,
    bool removeTerm
  ) public {
    require(term.termId > 0 && term.duration > 0, "invalid input");
    require(term.apr >= 1e27 && term.apr <= MAX_FIXED_TERM_APR, "invalid apr");

    // check if term already exists
    for (uint256 i = 0; i < fixedTerms.length; i++) {
      if (fixedTerms[i].termId == term.termId) {
        if (removeTerm) {
          // remove term by swapping with the last element and popping
          fixedTerms[i] = fixedTerms[fixedTerms.length - 1];
          fixedTerms.pop();
          emit FixedTermAndRateUpdated(term.termId, 0, 0);
        } else {
          // update existing term
          fixedTerms[i] = term;
          emit FixedTermAndRateUpdated(term.termId, term.duration, term.apr);
        }
        return;
      }
      require(fixedTerms[i].termId != term.termId, "invalid id");
    }
    // item not found
    // adding new term
    if (!removeTerm) {
      fixedTerms.push(term);
      emit FixedTermAndRateUpdated(term.termId, term.duration, term.apr);
    } else {
      revert("broker/term-not-found");
    }
  }
}
