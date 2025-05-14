pragma solidity 0.8.28;

import "forge-std/Script.sol";

import { MoolahVault } from "moolah-vault/MoolahVault.sol";
import { MarketParamsLib } from "moolah/libraries/MarketParamsLib.sol";
import { Id, MarketParams } from "moolah/interfaces/IMoolah.sol";

contract MoolahVaultConfigDeploy is Script {
  using MarketParamsLib for MarketParams;
  // todo update vault
  MoolahVault vault = MoolahVault(0x6d6783C146F2B0B2774C1725297f1845dc502525);
  uint256 fee = 10 * 1e16;
  address feeRecipient = 0x50dE2Fb5cd259c1b99DBD3Bb4E7Aac76BE7288fC;
  address skimRecipient = 0x6293e97900aA987Cf3Cbd419e0D5Ba43ebfA91c1;

  address WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
  address slisBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
  address asBNB = 0x77734e70b6E88b4d82fE632a168EDf6e700912b6;
  address BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
  address solvBTC = 0x4aae823a6a0b376De6A78e74eCC5b079d38cBCf7;
  address ptClisBNB = 0xb84cEC1Ab2af11b530ae0d8594B1493556be49Cd;
  address USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;

  address multiOracle = 0xf3afD82A4071f272F403dC176916141f44E6c750;
  address ptOracle = 0x1a438f71bc56514F47142c96A8f580AB5767aC17;

  address irm = 0xFe7dAe87Ebb11a7BEB9F534BB23267992d9cDe7c;

  uint256 lltv85 = 85 * 1e16;
  uint256 lltv915 = 915 * 1e15;

  bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 public constant MANAGER = keccak256("MANAGER");
  bytes32 public constant CURATOR = keccak256("CURATOR"); // manager role
  bytes32 public constant ALLOCATOR = keccak256("ALLOCATOR"); // manager role

  function run() public {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    console.log("Deployer: ", deployer);

    MarketParams memory slisBNBParams = MarketParams({
      loanToken: WBNB,
      collateralToken: slisBNB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv915
    });

    MarketParams memory asBNBParams = MarketParams({
      loanToken: WBNB,
      collateralToken: asBNB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv915
    });

    MarketParams memory BTCBParams = MarketParams({
      loanToken: WBNB,
      collateralToken: BTCB,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv85
    });

    MarketParams memory solvBTCParams = MarketParams({
      loanToken: WBNB,
      collateralToken: solvBTC,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv85
    });

    MarketParams memory ptClisBNBParams = MarketParams({
      loanToken: WBNB,
      collateralToken: ptClisBNB,
      oracle: ptOracle,
      irm: irm,
      lltv: lltv915
    });

    MarketParams memory USDCParams = MarketParams({
      loanToken: WBNB,
      collateralToken: USDC,
      oracle: multiOracle,
      irm: irm,
      lltv: lltv85
    });

    vm.startBroadcast(deployerPrivateKey);
    vault.setFeeRecipient(feeRecipient);
    vault.setSkimRecipient(skimRecipient);

    vault.grantRole(CURATOR, deployer);
    vault.grantRole(ALLOCATOR, deployer);

    // config vault
    vault.setFee(fee);

    vault.setCap(slisBNBParams, 10_000_000 ether);
    vault.setCap(asBNBParams, 10_000_000 ether);
    vault.setCap(BTCBParams, 10_000_000 ether);
    vault.setCap(solvBTCParams, 10_000_000 ether);
    vault.setCap(ptClisBNBParams, 10_000_000 ether);
    vault.setCap(USDCParams, 10_000_000 ether);

    Id slisBNBId = slisBNBParams.id();
    Id asBNBId = asBNBParams.id();
    Id BTCBId = BTCBParams.id();
    Id solvBTCId = solvBTCParams.id();
    Id ptClisBNBId = ptClisBNBParams.id();
    Id USDCId = USDCParams.id();
    Id[] memory supplyQueue = new Id[](6);
    supplyQueue[0] = slisBNBId;
    supplyQueue[1] = asBNBId;
    supplyQueue[2] = BTCBId;
    supplyQueue[3] = solvBTCId;
    supplyQueue[4] = ptClisBNBId;
    supplyQueue[5] = USDCId;

    vault.setSupplyQueue(supplyQueue);

    uint256[] memory withdrawQueue = new uint256[](6);
    withdrawQueue[0] = 5;
    withdrawQueue[1] = 4;
    withdrawQueue[2] = 3;
    withdrawQueue[3] = 2;
    withdrawQueue[4] = 1;
    withdrawQueue[5] = 0;
    vault.updateWithdrawQueue(withdrawQueue);

    vm.stopBroadcast();

    console.log("vault config done!");
  }
}
