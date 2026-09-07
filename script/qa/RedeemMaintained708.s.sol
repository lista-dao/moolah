// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

// CORRECTED testnet real-execution: drive the MAINTAINED testnet RevenueCollector
// (from qa-sc-automation/scripts/contracts.json: revenuecollector.bsc_test) instead of
// deploying a fresh one. Only seeds LP + wires feeTo + redeems on the existing instance.
//
// Run: PK=<hex> forge script script/qa/RedeemMaintained708.s.sol:RedeemMaintained708 \
//        --rpc-url https://bsc-testnet-dataseed.bnbchain.org --broadcast --slow

import "forge-std/Script.sol";
import { RevenueCollector } from "revenue/RevenueCollector.sol";
import { ERC20Mock } from "moolah/mocks/ERC20Mock.sol";

interface IV2Factory {
  function createPair(address, address) external returns (address);
  function setFeeTo(address) external;
  function feeTo() external view returns (address);
  function getPair(address, address) external view returns (address);
}
interface IV2Pair {
  function mint(address) external returns (uint256);
  function balanceOf(address) external view returns (uint256);
}

contract Seeder {
  function seed(address pair, address a, address b, uint256 amtA, uint256 amtB, address to) external returns (uint256) {
    ERC20Mock(a).transfer(pair, amtA);
    ERC20Mock(b).transfer(pair, amtB);
    return IV2Pair(pair).mint(to);
  }
}

contract RedeemMaintained708 is Script {
  // maintained addresses from the KV / contracts.json registry (bsc_test)
  address constant COLLECTOR = 0x163aC18E97a0be8894aa0baBDb0A65a32b151601; // revenuecollector.bsc_test
  address constant FACTORY = 0xD5397504095C424325416f0c83c42F5805626c54;   // its wired v2Factory

  function run() external {
    uint256 pk = vm.envUint("PK");
    address me = vm.addr(pk);
    RevenueCollector coll = RevenueCollector(payable(COLLECTOR));
    console.log("maintained collector:", COLLECTOR);
    console.log("collector.v2Factory():", coll.v2Factory());

    vm.startBroadcast(pk);

    // wire feeTo -> the MAINTAINED collector (I am feeToSetter). Fixes prior mis-wire too.
    IV2Factory(FACTORY).setFeeTo(COLLECTOR);
    require(IV2Factory(FACTORY).feeTo() == COLLECTOR, "feeTo not the maintained collector");

    // seed real LP into the maintained collector
    ERC20Mock a = new ERC20Mock();
    ERC20Mock b = new ERC20Mock();
    address pair = IV2Factory(FACTORY).createPair(address(a), address(b));
    Seeder s = new Seeder();
    a.setBalance(address(s), 100 ether);
    b.setBalance(address(s), 400 ether);
    uint256 liq = s.seed(pair, address(a), address(b), 100 ether, 400 ether, COLLECTOR);
    console.log("pair:", pair);
    console.log("LP seeded to maintained collector:", liq);

    // preview + REAL redeem as BOT(me) on the maintained instance
    (, address t0, uint256 pv0, address t1, uint256 pv1) = coll.previewRedeemV2Lp(pair);
    uint256 b0 = ERC20Mock(t0).balanceOf(COLLECTOR);
    uint256 b1 = ERC20Mock(t1).balanceOf(COLLECTOR);

    coll.redeemV2Lp(RevenueCollector.V2LpRedemption({ lpToken: pair, minAmount0: pv0, minAmount1: pv1 }));

    console.log("redeemed amount0:", ERC20Mock(t0).balanceOf(COLLECTOR) - b0);
    console.log("redeemed amount1:", ERC20Mock(t1).balanceOf(COLLECTOR) - b1);
    console.log("collector LP after:", IV2Pair(pair).balanceOf(COLLECTOR));
    require(IV2Pair(pair).balanceOf(COLLECTOR) == 0, "LP not burned");

    vm.stopBroadcast();
    console.log("OK: redeem on MAINTAINED testnet collector complete");
  }
}
