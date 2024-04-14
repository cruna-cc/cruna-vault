// SPDX-License-Identifier: GPL3
pragma solidity ^0.8.20;

// Author: Francesco Sullo <francesco@sullo.co>
//
import {IERC165, ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IManagedNFT, ICrunaProtectedNFT} from "./ICrunaProtectedNFT.sol";
import {IERC6454} from "../erc/IERC6454.sol";
import {IERC6982} from "../erc/IERC6982.sol";
import {ICrunaManager} from "../manager/ICrunaManager.sol";
import {IVersioned} from "../utils/IVersioned.sol";
import {Deployed} from "../utils/Deployed.sol";
import {Canonical} from "../libs/Canonical.sol";
import {ICrunaService} from "../services/ICrunaService.sol";

//import "hardhat/console.sol";

/**
 * A convenient interface to mix nameId, version and default implementations
 */
interface IVersionedManager {
  // solhint-disable-next-line func-name-mixedcase
  function DEFAULT_IMPLEMENTATION() external pure returns (address);

  function version() external pure returns (uint256);

  function nameId() external pure returns (bytes4);
}

/**
 * @title CrunaProtectedNFT
 * @notice This contracts is a base for NFTs with protected transfers. It must be extended implementing
 * the _canManage function to define who can alter the contract. Two versions are provided in this repo,CrunaProtectedNFTTimeControlled.sol and CrunaProtectedNFTOwnable.sol. The first is the recommended one, since it allows a governance aligned with best practices. The second is simpler, and can be used in less critical scenarios. If none of them fits your needs, you can implement your own policy.
 */
abstract contract CrunaProtectedNFT is ICrunaProtectedNFT, IVersioned, IERC6454, IERC6982, Deployed, ERC721, ReentrancyGuard {
  using ECDSA for bytes32;
  using Strings for uint256;
  using Address for address;

  /**
   * @notice Set a convenient variable to refer to the contract itself
   */
  address internal immutable _SELF = address(this);

  /**
   * @notice The configuration of the NFT
   */
  NftConf internal _nftConf;

  /**
   * @notice The manager history
   */
  ManagerHistory[] internal _managerHistory;

  /**
   * @notice internal variable used to make protected NFT temporarily transferable.
   * It is set before the transfer and removed after it, during the manager transfer process.
   */
  mapping(uint256 tokenId => uint256 approved) internal _approvedTransfers;

  /**
   * @notice allows only the manager of a certain tokenId to call the function.
   * @param tokenId The id of the token.
   */
  modifier onlyManagerOf(uint256 tokenId) {
    if (_managerOf(tokenId) != _msgSender()) revert NotTheManager();
    _;
  }

  /// @dev see {ICrunaProtectedNFT-nftConf}
  function nftConf() external view virtual override returns (NftConf memory) {
    return _nftConf;
  }

  /// @dev see {ICrunaProtectedNFT-managerHistory}
  function managerHistory(uint256 index) external view virtual override returns (ManagerHistory memory) {
    if (index >= _nftConf.managerHistoryLength) revert InvalidIndex();
    return _managerHistory[index];
  }

  /// @dev see {IVersioned-version}
  function version() external pure virtual returns (uint256) {
    // semver 1.2.3 => 1002003 = 1e6 + 2e3 + 3
    return 1_000_000;
  }

  constructor(string memory name_, string memory symbol_) payable ERC721(name_, symbol_) {
    emit DefaultLocked(false);
  }

  /// @dev see {ICrunaProtectedNFT-init}
  function init(
    address managerAddress_,
    bool progressiveTokenIds_,
    uint96 nextTokenId_,
    uint96 maxTokenId_
  ) external virtual override {
    _canManage(true);
    if (_nftConf.managerHistoryLength != 0) revert AlreadyInitiated();
    if (managerAddress_ == address(0)) revert ZeroAddress();
    _nftConf = NftConf({
      progressiveTokenIds: progressiveTokenIds_,
      nextTokenId: nextTokenId_,
      maxTokenId: maxTokenId_,
      managerHistoryLength: 1,
      unusedField: 0
    });
    _managerHistory.push(ManagerHistory({managerAddress: managerAddress_, firstTokenId: nextTokenId_, lastTokenId: 0}));
  }

  /// @dev see {ICrunaProtectedNFT-setMaxTokenId}
  function setMaxTokenId(uint96 maxTokenId_) external virtual {
    _canManage(_nftConf.maxTokenId == 0);
    if (maxTokenId_ == 0) revert InvalidMaxTokenId();
    if (_nftConf.progressiveTokenIds)
      if (_nftConf.nextTokenId > maxTokenId_ + 1) revert InvalidMaxTokenId();
    _nftConf.maxTokenId = maxTokenId_;
    emit MaxTokenIdChange(maxTokenId_);
  }

  /// @dev see {ICrunaProtectedNFT-defaultManagerImplementation}
  function defaultManagerImplementation(uint256 _tokenId) external view virtual override returns (address) {
    return _defaultManagerImplementation(_tokenId);
  }

  /// @dev see {ICrunaProtectedNFT-upgradeDefaultManager}
  function upgradeDefaultManager(address payable newManagerProxy) external virtual nonReentrant {
    _canManage(false);
    if (!_nftConf.progressiveTokenIds) revert NotAvailableIfTokenIdsAreNotProgressive();
    IVersionedManager newManager = IVersionedManager(newManagerProxy);
    if (!Canonical.crunaGuardian().trustedImplementation(newManager.nameId(), newManager.DEFAULT_IMPLEMENTATION()))
      revert UntrustedImplementation(newManagerProxy);
    address lastEmitter = _managerHistory[_nftConf.managerHistoryLength - 1].managerAddress;
    if (newManager.version() <= IVersionedManager(lastEmitter).version()) revert CannotUpgradeToAnOlderVersion();
    _managerHistory[_nftConf.managerHistoryLength - 1].lastTokenId = _nftConf.nextTokenId - 1;
    _managerHistory.push(ManagerHistory({managerAddress: newManagerProxy, firstTokenId: _nftConf.nextTokenId, lastTokenId: 0}));
    _nftConf.managerHistoryLength++;
    emit DefaultManagerUpgrade(newManagerProxy);
  }

  /**
   * @notice see {ICrunaProtectedNFT-managedTransfer}.
   */
  function managedTransfer(
    bytes4 pluginNameId,
    uint256 tokenId,
    address to
  ) external payable virtual override onlyManagerOf(tokenId) {
    _approvedTransfers[tokenId] = 1;
    _approve(_managerOf(tokenId), tokenId, address(0));
    safeTransferFrom(ownerOf(tokenId), to, tokenId);
    _approve(address(0), tokenId, address(0));
    delete _approvedTransfers[tokenId];
    emit ManagedTransfer(pluginNameId, tokenId);
  }

  /// @dev see {ERC165-supportsInterface}.
  function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721, IERC165) returns (bool) {
    return
      interfaceId == type(IManagedNFT).interfaceId ||
      interfaceId == type(IERC6454).interfaceId ||
      interfaceId == type(IERC6982).interfaceId ||
      super.supportsInterface(interfaceId);
  }

  /// @dev see {IERC6454-isTransferable}
  function isTransferable(uint256 tokenId, address from, address to) external view virtual override returns (bool) {
    return _isTransferable(tokenId, from, to);
  }

  /// @dev see {IERC6982-defaultLocked}
  function defaultLocked() external pure virtual override returns (bool) {
    return false;
  }

  /// @dev see {IERC6982-locked}
  function locked(uint256 tokenId) external view virtual override returns (bool) {
    return ICrunaManager(_managerOf(tokenId)).locked();
  }

  /**
   * @notice Emit a Locked event when a protector is set and the token becomes locked.
   * This function is not virtual because should not be overridden to avoid issues when
   * called by the manager (when protectors are set/unset)
   * Making it payable reduces the gas cost.
   */
  function emitLockedEvent(uint256 tokenId, bool locked_) external payable onlyManagerOf(tokenId) {
    emit Locked(tokenId, locked_);
  }

  /// @dev see {ICrunaProtectedNFT-deployService}
  function deployService(
    address implementation,
    bytes32 salt,
    uint256 tokenId,
    bool isERC6551Account,
    bytes memory data
  ) external payable virtual override {
    if (_msgSender() != ownerOf(tokenId)) revert NotTheTokenOwner();
    ICrunaService service = ICrunaService(implementation);
    if (service.isManaged()) revert ManagedService();
    bool previouslyDeployed = _isDeployed(implementation, salt, _SELF, tokenId, isERC6551Account);
    address addr = _deploy(implementation, salt, _SELF, tokenId, isERC6551Account);
    if (!previouslyDeployed) {
      service = ICrunaService(addr);
      service.init(data);
    }
  }

  /// @dev see {ICrunaProtectedNFT-isDeployed}
  function isDeployed(
    address implementation,
    bytes32 salt,
    uint256 tokenId,
    bool isERC6551Account
  ) external view virtual returns (bool) {
    return _isDeployed(implementation, salt, _SELF, tokenId, isERC6551Account);
  }

  /// @dev see {ICrunaProtectedNFT-managerOf}
  function managerOf(uint256 tokenId) external view virtual returns (address) {
    return _managerOf(tokenId);
  }

  /**
   * @notice internal function to return the manager (for lesser gas consumption)
   * @param tokenId the id of the token
   * @return the address of the manager
   */
  function _managerOf(uint256 tokenId) internal view virtual returns (address) {
    return _addressOfDeployed(_defaultManagerImplementation(tokenId), 0x00, _SELF, tokenId, false);
  }

  /// @dev see {ICrunaProtectedNFT-addressOfDeployed}
  function addressOfDeployed(
    address implementation,
    bytes32 salt,
    uint256 tokenId,
    bool isERC6551Account
  ) external view virtual override returns (address) {
    return _addressOfDeployed(implementation, salt, _SELF, tokenId, isERC6551Account);
  }

  /**
   * @notice Returns the default implementation of the manager for a specific tokenId
   * @param _tokenId the tokenId
   * @return The address of the implementation
   */
  function _defaultManagerImplementation(uint256 _tokenId) internal view virtual returns (address) {
    if (_nftConf.managerHistoryLength == 1) return _managerHistory[0].managerAddress;
    uint256 len = _nftConf.managerHistoryLength;
    for (uint256 i; i < len; ) {
      if (
        _tokenId >= _managerHistory[i].firstTokenId &&
        (_managerHistory[i].lastTokenId == 0 || _tokenId <= _managerHistory[i].lastTokenId)
      ) return _managerHistory[i].managerAddress;
      unchecked {
        ++i;
      }
    }
    // should never happen
    return address(0);
  }

  /**
   * @notice Specify if the caller can call some function.
   * Must be overridden to specify who can manage changes during initialization and later
   * @param isInitializing If true, the function is being called during initialization, if false,
   * it is supposed to the called later. A time controlled NFT can allow the admin to call some
   * functions during the initialization, requiring later a standard proposal/execition process.
   */
  function _canManage(bool isInitializing) internal view virtual;

  /**
   * @notice see {ERC721-_update}.
   */
  function _update(address to, uint256 tokenId, address auth) internal virtual override(ERC721) returns (address) {
    if (_isTransferable(tokenId, _ownerOf(tokenId), to)) {
      return super._update(to, tokenId, auth);
    }
    revert NotTransferable();
  }

  /**
   * @notice Function to define a token as transferable or not, according to IERC6454
   * @param tokenId The id of the token.
   * @param from The address of the sender.
   * @param to The address of the recipient.
   * @return true if the token is transferable, false otherwise.
   */
  function _isTransferable(uint256 tokenId, address from, address to) internal view virtual returns (bool) {
    ICrunaManager manager = ICrunaManager(_managerOf(tokenId));
    // Burnings and self transfers are not allowed
    if (to == address(0) || from == to) return false;
    // if from zero, it is minting
    if (from == address(0)) return true;
    _requireOwned(tokenId);
    return manager.isTransferable(to) || _approvedTransfers[tokenId] == 1;
  }

  /**
   * @notice Mints tokens by amount.
   * @dev It works only if nftConf.progressiveTokenIds is true.
   * @param to The address of the recipient.
   * @param amount The amount of tokens to mint.
   */
  function _mintAndActivateByAmount(address to, uint256 amount) internal virtual {
    if (!_nftConf.progressiveTokenIds) revert NotAvailableIfTokenIdsAreNotProgressive();
    if (_nftConf.managerHistoryLength == 0) revert NftNotInitiated();
    uint256 tokenId = _nftConf.nextTokenId;
    for (uint256 i; i < amount; ) {
      unchecked {
        _mintAndActivate(to, tokenId++);
        ++i;
      }
    }
    _nftConf.nextTokenId = uint96(tokenId);
  }

  /**
   * @notice This function will mint a new token and initialize it.
   * @dev Use it carefully if nftConf.progressiveTokenIds is true. Usually, you may
   * want to do so if you reserved some specific token to the project itself, the DAO, etc.
   * An example:
   * You reserve 1000 tokens to the DAO, `nextTokenId` will be 1001.
   * If you have a function the uses directly _mintAndActivate you MUST set a check
   * to avoid minting tokens with higher id than `nextTokenId`. If than happens, when
   * you call again _mintAndActivateByAmount, if one of the supposed tokens is already minted,
   * the function will revert and the error may be unfixable.
   * @param to The address of the recipient.
   * @param tokenId The id of the token.
   */
  function _mintAndActivate(address to, uint256 tokenId) internal virtual {
    if (_nftConf.managerHistoryLength == 0) revert NftNotInitiated();
    if (
      tokenId > type(uint96).max ||
      (_nftConf.maxTokenId != 0 && tokenId > _nftConf.maxTokenId) ||
      (tokenId < _managerHistory[0].firstTokenId)
    ) revert InvalidTokenId();
    _deploy(_defaultManagerImplementation(tokenId), 0x00, _SELF, tokenId, false);
    _safeMint(to, tokenId++);
  }
}
