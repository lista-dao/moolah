// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IAccessControlEnumerable } from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IStableSwapLP } from "./interfaces/IStableSwapLP.sol";
import "./interfaces/IStableSwap.sol";

contract StableSwapFactory is UUPSUpgradeable, AccessControlEnumerableUpgradeable {
  uint256 constant N_COINS = 2;

  /// @notice check lp token contract before deploy
  address public lpImpl;
  /// @notice check swap contract before deploy
  address public swapImpl;

  mapping(address => mapping(address => StableSwapPairInfo)) public stableSwapPairInfo;
  mapping(uint256 => address) public swapPairContract;
  uint256 public pairLength;

  bytes32 public DEPLOYER = keccak256("DEPLOYER");

  struct StableSwapPairInfo {
    address swapContract;
    address token0;
    address token1;
    address LPContract;
  }

  event NewStableSwapPair(address indexed swapContract, address tokenA, address tokenB, address lp);
  event NewStableSwapLP(address indexed swapLPContract, address tokenA, address tokenB);
  event SetLpImplementation(address newLpImpl);
  event SetSwapImplementation(address newSwapImpl);

  constructor() {
    _disableInitializers();
  }

  function initialize(address admin, address[] memory deployers) public initializer {
    require(admin != address(0), "Zero address");

    __AccessControl_init();
    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    for (uint256 i = 0; i < deployers.length; i++) {
      _grantRole(DEPLOYER, deployers[i]);
    }
  }

  // returns sorted token addresses, used to handle return values from pairs sorted in this order
  function sortTokens(address tokenA, address tokenB) public pure returns (address token0, address token1) {
    require(tokenA != tokenB, "IDENTICAL_ADDRESSES");
    (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
  }
  /**
   * @dev createSwapLP
   * @param _tokenA: Addresses of ERC20 conracts
   * @param _tokenB: Addresses of ERC20 conracts
   * @param _name: name of LP token
   * @param _symbol: symbol of LP token
   */
  function createSwapLP(
    address _tokenA,
    address _tokenB,
    string memory _name,
    string memory _symbol
  ) public onlyRole(DEPLOYER) returns (address) {
    require(lpImpl != address(0), "LP implementation not set");

    // create LP token
    address admin = address(this);
    address minter = address(this);
    ERC1967Proxy proxy = new ERC1967Proxy(
      lpImpl,
      abi.encodeWithSignature("initialize(address,address,string,string)", admin, minter, _name, _symbol)
    );

    // minter is factory contract
    address lpToken = address(proxy);

    emit NewStableSwapLP(lpToken, _tokenA, _tokenB);
    return lpToken;
  }

  function _createSwapPair(
    address _tokenA,
    address _tokenB,
    uint256 _A,
    uint256 _fee,
    uint256 _admin_fee,
    address _admin,
    address _manager,
    address _pauser,
    address _lp,
    address _oracle
  ) internal returns (address) {
    require(swapImpl != address(0), "Swap implementation not set");
    require(_tokenA != address(0) && _tokenB != address(0) && _tokenA != _tokenB, "Illegal token");

    (address t0, address t1) = sortTokens(_tokenA, _tokenB);
    address[N_COINS] memory coins = [t0, t1];

    // create swap contract
    ERC1967Proxy swapContract = new ERC1967Proxy(
      swapImpl,
      abi.encodeWithSignature(
        "initialize(address[2],uint256,uint256,uint256,address,address,address,address,address)",
        coins,
        _A,
        _fee,
        _admin_fee,
        _admin,
        _manager,
        _pauser,
        _lp,
        _oracle
      )
    );

    return address(swapContract);
  }

  /**
   * @notice createSwapPair
   * @param _tokenA: Addresses of ERC20 conracts .
   * @param _tokenB: Addresses of ERC20 conracts .
   * @param _A: Amplification coefficient multiplied by n * (n - 1)
   * @param _fee: Fee to charge for exchanges
   * @param _admin_fee: Admin fee
   */
  function createSwapPair(
    address _tokenA,
    address _tokenB,
    string memory _name,
    string memory _symbol,
    uint256 _A,
    uint256 _fee,
    uint256 _admin_fee,
    address _admin,
    address _manager,
    address _pauser,
    address _oracle
  ) external onlyRole(DEPLOYER) returns (address lp, address swapContract) {
    require(swapImpl != address(0) && lpImpl != address(0), "Implementation not set");
    require(_tokenA != address(0) && _tokenB != address(0) && _tokenA != _tokenB, "Illegal token");
    (address t0, address t1) = sortTokens(_tokenA, _tokenB);

    // 1. create LP token; tranfer admin role after set minter
    lp = createSwapLP(t0, t1, _name, _symbol);

    // 2. create stable swap pool
    swapContract = _createSwapPair(t0, t1, _A, _fee, _admin_fee, _admin, _manager, _pauser, lp, _oracle);

    // 3. transfer minter to swap contract; TODO tranfer admin role of lp to _admin
    IStableSwapLP(lp).setMinter(swapContract);
    IAccessControlEnumerable(lp).grantRole(DEFAULT_ADMIN_ROLE, _admin);
    IAccessControlEnumerable(lp).revokeRole(DEFAULT_ADMIN_ROLE, address(this));
    addPairInfoInternal(swapContract, t0, t1, lp);
  }

  function addPairInfoInternal(address _swapContract, address _t0, address _t1, address _lp) internal {
    StableSwapPairInfo storage info = stableSwapPairInfo[_t0][_t1];
    info.swapContract = _swapContract;
    info.token0 = _t0;
    info.token1 = _t1;
    info.LPContract = _lp;
    swapPairContract[pairLength] = _swapContract;
    pairLength += 1;

    emit NewStableSwapPair(_swapContract, _t0, _t1, _lp);
  }

  function addPairInfo(address _swapContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
    IStableSwap swap = IStableSwap(_swapContract);
    uint256 n_coins = swap.N_COINS();
    require(n_coins == 2, "Only support 2 coins pool");
    addPairInfoInternal(_swapContract, swap.coins(0), swap.coins(1), swap.token());
  }

  function setImpls(address _newLpImpl, address _newSwapImpl) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(_newLpImpl != address(0) && _newSwapImpl != address(0), "Zero address");

    if (_newLpImpl != lpImpl) {
      lpImpl = _newLpImpl;
      emit SetLpImplementation(_newLpImpl);
    }

    if (_newSwapImpl != swapImpl) {
      swapImpl = _newSwapImpl;
      emit SetSwapImplementation(_newSwapImpl);
    }
  }

  function getPairInfo(address _tokenA, address _tokenB) external view returns (StableSwapPairInfo memory info) {
    (address t0, address t1) = sortTokens(_tokenA, _tokenB);
    StableSwapPairInfo memory pairInfo = stableSwapPairInfo[t0][t1];
    info.swapContract = pairInfo.swapContract;
    info.token0 = pairInfo.token0;
    info.token1 = pairInfo.token1;
    info.LPContract = pairInfo.LPContract;
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
