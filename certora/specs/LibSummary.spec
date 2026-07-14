// SPDX-License-Identifier: GPL-2.0-or-later

import "ProxyFilters.spec";

using Util as Util;

methods {

    function Util.libMulDivUp(uint256, uint256, uint256) external returns uint256 envfree;
    function Util.libMulDivDown(uint256, uint256, uint256) external returns uint256 envfree;
    function Util.libId(MoolahHarness.MarketParams) external returns MoolahHarness.Id envfree;
    function Util.refId(MoolahHarness.MarketParams) external returns MoolahHarness.Id envfree;
    function Util.libMin(uint256 x, uint256 y) external returns uint256 envfree;
}

// Check the summary of MathLib.mulDivUp required by ExchangeRate.spec
rule checkSummaryMulDivUp(uint256 x, uint256 y, uint256 d) {
    uint256 result = Util.libMulDivUp(x, y, d);
    assert result * d >= x * y;
}

// Check the summary of MathLib.mulDivDown required by ExchangeRate.spec
rule checkSummaryMulDivDown(uint256 x, uint256 y, uint256 d) {
    uint256 result = Util.libMulDivDown(x, y, d);
    assert result * d <= x * y;
}

// Check the summary of MarketParamsLib.id required by Liveness.spec
rule checkSummaryId(MoolahHarness.MarketParams marketParams) {
    assert Util.libId(marketParams) == Util.refId(marketParams);
}

rule checkSummaryMin(uint256 x, uint256 y) {
    uint256 refMin = x < y ? x : y;
    assert Util.libMin(x, y) == refMin;
}
