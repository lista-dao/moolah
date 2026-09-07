// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

// exec-verify contract-profile TESTNET REAL-BROADCAST tier for task 708 / moolah PR#241.
// Deploys a fresh RevenueCollector on BSC testnet, wires it to the live Lista V2 testnet
// factory, seeds real LP, and broadcasts a REAL redeemV2Lp tx. Everything signed by PK.
//
// Run: PK=<hex> forge script script/qa/Redeem708Testnet.s.sol:Redeem708Testnet \
//        --rpc-url https://bsc-testnet-dataseed.bnbchain.org --broadcast --slow

import "forge-std/Script.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { RevenueCollector } from "revenue/RevenueCollector.sol";
import { ERC20Mock } from "moolah/mocks/ERC20Mock.sol";

interface IV2Factory {
  function createPair(address tokenA, address tokenB) external returns (address pair);
  function setFeeTo(address) external;
  function feeTo() external view returns (address);
  function getPair(address, address) external view returns (address);
}

interface IV2Pair {
  function mint(address to) external returns (uint256 liquidity);
  function token0() external view returns (address);
  function token1() external view returns (address);
  function totalSupply() external view returns (uint256);
  function balanceOf(address) external view returns (uint256);
  function getReserves() external view returns (uint112, uint112, uint32);
}

/// @dev Atomic LP seeder: transfer both tokens to the pair and mint LP to `lpTo` in ONE tx,
///      closing the skim-bot front-run window (mainnet skim bot lesson) even on testnet.
contract Seeder {
  function seed(address pair, address a, address b, uint256 amtA, uint256 amtB, address lpTo) external returns (uint256) {
    ERC20Mock(a).transfer(pair, amtA);
    ERC20Mock(b).transfer(pair, amtB);
    return IV2Pair(pair).mint(lpTo);
  }
}

contract Redeem708Testnet is Script {
  address constant FACTORY = 0xD5397504095C424325416f0c83c42F5805626c54; // Lista V2 testnet factory

  function run() external {
    uint256 pk = vm.envUint("PK");
    address me = vm.addr(pk);
    console.log("signer:", me);

    vm.startBroadcast(pk);

    // 1. mock tokens
    ERC20Mock a = new ERC20Mock();
    ERC20Mock b = new ERC20Mock();
    console.log("tokenA:", address(a));
    console.log("tokenB:", address(b));

    // 2. fresh RevenueCollector (admin=manager=bot=me so I can wire + redeem)
    RevenueCollector impl = new RevenueCollector();
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(impl),
      abi.encodeWithSelector(impl.initialize.selector, me, me, me, new address[](0), new address[](0))
    );
    RevenueCollector coll = RevenueCollector(payable(address(proxy)));
    console.log("collector impl:", address(impl));
    console.log("collector proxy:", address(coll));

    // 3. pair + provenance wiring
    address pair = IV2Factory(FACTORY).createPair(address(a), address(b));
    console.log("pair:", pair);
    IV2Factory(FACTORY).setFeeTo(address(coll)); // I am feeToSetter
    coll.setV2Factory(FACTORY);
    require(IV2Factory(FACTORY).feeTo() == address(coll), "feeTo not wired");
    require(IV2Factory(FACTORY).getPair(address(a), address(b)) == pair, "pair not registered");

    // 4. seed real LP into the collector atomically
    Seeder seeder = new Seeder();
    a.setBalance(address(seeder), 100 ether);
    b.setBalance(address(seeder), 400 ether);
    uint256 liq = seeder.seed(pair, address(a), address(b), 100 ether, 400 ether, address(coll));
    console.log("LP minted to collector:", liq);
    require(IV2Pair(pair).balanceOf(address(coll)) == liq, "collector LP mismatch");

    // 5. preview then REAL redeem as BOT(me)
    (uint256 pvLp, address t0, uint256 pv0, address t1, uint256 pv1) = coll.previewRedeemV2Lp(pair);
    console.log("preview lp/amount0/amount1:", pvLp, pv0, pv1);

    uint256 t0Before = ERC20Mock(t0).balanceOf(address(coll));
    uint256 t1Before = ERC20Mock(t1).balanceOf(address(coll));

    RevenueCollector.V2LpRedemption memory r = RevenueCollector.V2LpRedemption({
      lpToken: pair,
      minAmount0: pv0, // require exactly the previewed amounts (first-mint pair => no fee drift)
      minAmount1: pv1
    });
    coll.redeemV2Lp(r);

    // 6. on-chain assertions
    uint256 got0 = ERC20Mock(t0).balanceOf(address(coll)) - t0Before;
    uint256 got1 = ERC20Mock(t1).balanceOf(address(coll)) - t1Before;
    console.log("redeemed amount0/amount1:", got0, got1);
    console.log("collector LP after:", IV2Pair(pair).balanceOf(address(coll)));
    require(got0 == pv0 && got1 == pv1, "redeem output != preview");
    require(IV2Pair(pair).balanceOf(address(coll)) == 0, "LP not fully burned");

    vm.stopBroadcast();

    console.log("OK: real testnet redeem broadcast complete");
  }
}
