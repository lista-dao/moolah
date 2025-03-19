pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { MoolahVault } from "moolah-vault/MoolahVault.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { Id, MarketParams } from "moolah/interfaces/IMoolah.sol";

contract MoolahVaultConfigDeploy is Script {
  using MarketParamsLib for MarketParams;
  // todo
  MoolahVault vault = MoolahVault(0xA5edCb7c60448f7779361afc2F92f858f3A6dd1E);
  uint256 fee = 10 * 1e16;
  address feeRecipient = 0x05E3A7a66945ca9aF73f66660f22ffB36332FA54;
  address skimRecipient = 0x05E3A7a66945ca9aF73f66660f22ffB36332FA54;

  address WBNB = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;
  address BTCB = 0x4BB2f2AA54c6663BFFD37b54eCd88eD81bC8B3ec;
  address slisBNB = 0xCc752dC4ae72386986d011c2B485be0DAd98C744;
  address ptClisBNB25apr = 0x0A9498fb5B811E1AC4369bcdce427f7a3D2816eB;
  address solvBTC = 0xB1E63330f4718772CF939128d222389b30C70cF2;
  address multiOracle = 0x002d038Ada9BEF58e23587348cBcd75075514FD2;
  address irm = 0x803da834B2Ff96D9055F1057dd8907AD776bEAA1;

  uint256 lltv70 = 70 * 1e16;
  uint256 lltv80 = 80 * 1e16;
  uint256 lltv90 = 90 * 1e16;

  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant CURATOR = keccak256("CURATOR"); // manager role
  bytes32 public constant ALLOCATOR = keccak256("ALLOCATOR"); // manager role

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    // collateral-BTCB loan-WBNB lltv-80%
    MarketParams memory BTCBParams = MarketParams({
      loanToken: WBNB,
      collateralToken: BTCB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv80
    });
    // collateral-slisBNB loan-WBNB lltv-80%
    MarketParams memory slisBNBParams = MarketParams({
      loanToken: WBNB,
      collateralToken: slisBNB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv80
    });
    // collateral-ptClisBNB25apr loan-WBNB lltv-90%
    MarketParams memory ptClisBNB25aprParams = MarketParams({
      loanToken: WBNB,
      collateralToken: ptClisBNB25apr,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv90
    });
    // collateral-solvBTC loan-WBNB lltv-70%
    MarketParams memory solvBTCParams = MarketParams({
      loanToken: WBNB,
      collateralToken: solvBTC,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv70
    });

    vm.startBroadcast(deployerPrivateKey);
    vault.setFeeRecipient(feeRecipient);
    vault.setSkimRecipient(skimRecipient);

    vault.grantRole(CURATOR, deployer);
    vault.grantRole(ALLOCATOR, deployer);

    // config vault
    vault.setFee(fee);

    // BTCB cap 89286 WBNB
    vault.setCap(BTCBParams, 89286 ether);
    // slisBNB cap 16234 WBNB
    vault.setCap(slisBNBParams, 16234 ether);
    // ptClisBNB25apr cap 40584 WBNB
    vault.setCap(ptClisBNB25aprParams, 40584 ether);
    // solvBTC cap 16234 WBNB
    vault.setCap(solvBTCParams, 16234 ether);

    Id BTCBId = BTCBParams.id();
    Id slisBNBId = slisBNBParams.id();
    Id ptClisBNB25aprId = ptClisBNB25aprParams.id();
    Id solvBTCId = solvBTCParams.id();
    Id[] memory supplyQueue = new Id[](4);
    supplyQueue[0] = BTCBId;
    supplyQueue[1] = slisBNBId;
    supplyQueue[2] = ptClisBNB25aprId;
    supplyQueue[3] = solvBTCId;

    vault.setSupplyQueue(supplyQueue);

    uint256[] memory withdrawQueue = new uint256[](4);
    withdrawQueue[0] = 3;
    withdrawQueue[1] = 2;
    withdrawQueue[2] = 1;
    withdrawQueue[3] = 0;
    vault.updateWithdrawQueue(withdrawQueue);

    vm.stopBroadcast();

    console.log("vault config done!");
  }
}
