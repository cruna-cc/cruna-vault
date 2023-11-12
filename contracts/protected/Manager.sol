// SPDX-License-Identifier: GPL3
pragma solidity ^0.8.19;

// Author: Francesco Sullo <francesco@sullo.co>

import {IERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {IAccountGuardian} from "@tokenbound/contracts/interfaces/IAccountGuardian.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";

import {ERC6551AccountLib} from "erc6551/lib/ERC6551AccountLib.sol";
import {IERC6551Account} from "erc6551/interfaces/IERC6551Account.sol";
import {ManagerSigner} from "./ManagerSigner.sol";

import {Protected} from "./Protected.sol";
import {Actor, IActor} from "./Actor.sol";
import {IManager} from "./IManager.sol";

import "@tokenbound/contracts/utils/Errors.sol" as Errors;

//import {console} from "hardhat/console.sol";

contract Manager is IManager, Actor, Context, ERC721Holder, UUPSUpgradeable, IERC1271 {
  using ECDSA for bytes32;
  using Strings for uint256;
  IAccountGuardian public guardian;
  ManagerSigner public managerSigner;
  Protected public immutable VAULT;

  // the address of a second wallet required to validate the transfer of a token
  // the user can set up to 2 protectors
  // owner >> protector >> approved
  //  mapping(address => Protector[]) private _protectors;

  // the address of the owner given the second wallet required to start the transfer
  mapping(address => address) internal _ownersByProtector;

  // the tokens currently being transferred when a second wallet is set
  //  mapping(uint256 => ControlledTransfer) private _controlledTransfers;
  mapping(bytes32 => bool) internal _usedSignatures;

  mapping(address => BeneficiaryRequest) internal _beneficiariesRequests;

  mapping(address => BeneficiaryConf) internal _beneficiaryConfs;

  modifier onlyTokenOwner() {
    if (VAULT.ownerOf(tokenId()) != _msgSender()) revert NotTheTokenOwner();
    _;
  }

  modifier onlyTokensOwner() {
    if (VAULT.balanceOf(_msgSender()) == 0) revert NotATokensOwner();
    _;
  }

  constructor() {
    VAULT = Protected(msg.sender);
  }

  // this must be execute immediately after the deployment
  function init(string memory name, string memory version, address guardian_) external {
    if (msg.sender != address(VAULT)) revert Forbidden();
    guardian = IAccountGuardian(guardian_);
    managerSigner = new ManagerSigner(name, version);
  }

  function _authorizeUpgrade(address implementation) internal virtual override {
    if (!guardian.isTrustedImplementation(implementation)) revert Errors.InvalidImplementation();
    if (!_isValidSigner(msg.sender)) revert Errors.NotAuthorized();
  }

  function isValidSigner(address signer, bytes calldata) external view virtual returns (bytes4) {
    if (_isValidSigner(signer)) {
      return IERC6551Account.isValidSigner.selector;
    }

    return bytes4(0);
  }

  function isValidSignature(bytes32 hash, bytes memory signature) external view virtual returns (bytes4 magicValue) {
    bool isValid = SignatureChecker.isValidSignatureNow(owner(), hash, signature);

    if (isValid) {
      return IERC1271.isValidSignature.selector;
    }

    return bytes4(0);
  }

  function token() public view virtual returns (uint256, address, uint256) {
    return ERC6551AccountLib.token();
  }

  function owner() public view virtual returns (address) {
    (uint256 chainId, address tokenContract_, uint256 tokenId_) = token();
    if (chainId != block.chainid) return address(0);

    return IERC721(tokenContract_).ownerOf(tokenId_);
  }

  function _isValidSigner(address signer) internal view virtual returns (bool) {
    return signer == owner();
  }

  function tokenAddress() public view returns (address) {
    (, address tokenContract_, ) = token();
    return tokenContract_;
  }

  function tokenId() public view returns (uint256) {
    (, , uint256 tokenId_) = token();
    return tokenId_;
  }

  function onERC721Received(address, address, uint256, bytes memory) public virtual override returns (bytes4) {
    // This contract is not supposed to own vaults itself
    if (VAULT.balanceOf(address(this)) > 0) revert Errors.OwnershipCycle();
    return this.onERC721Received.selector;
  }

  // actors

  function countActiveProtectors(address tokensOwner_) public view override returns (uint256) {
    return _countActiveActorsByRole(tokensOwner_, _role("PROTECTOR"));
  }

  function findProtector(address tokensOwner_, address protector_) public view override returns (uint256, Status) {
    (uint256 i, IActor.Actor storage actor) = _getActor(tokensOwner_, protector_, _role("PROTECTOR"));
    return (i, actor.status);
  }

  function isProtectorFor(address tokensOwner_, address protector_) public view returns (bool) {
    Status status = _actorStatus(tokensOwner_, protector_, _role("PROTECTOR"));
    return status == Status.ACTIVE;
  }

  function hasProtectors(address tokensOwner_) public view override returns (address[] memory) {
    return _listActiveActors(tokensOwner_, _role("PROTECTOR"));
  }

  function setProtector(
    address protector_,
    bool active,
    uint256 timestamp,
    uint256 validFor,
    bytes calldata signature
  ) external virtual override onlyTokensOwner {
    if (protector_ == address(0)) revert NoZeroAddress();
    if (protector_ == _msgSender()) revert CannotBeYourself();
    _checkIfSignatureUsedAndUseIfNot(signature);
    isNotExpired(timestamp, validFor);
    address signer = managerSigner.signRequest(protector_, address(0), (active ? 1 : 0), timestamp, validFor, signature);
    if (active) {
      if (_ownersByProtector[protector_] != address(0)) {
        if (_ownersByProtector[protector_] == _msgSender()) revert ProtectorAlreadySetByYou();
        else revert AssociatedToAnotherOwner();
      }
      Status status = _actorStatus(_msgSender(), protector_, _role("PROTECTOR"));
      if (countActiveProtectors(_msgSender()) == 0) {
        if (protector_ != signer) revert WrongDataOrNotSignedByProposedProtector();
      } else {
        isSignerAProtector(_msgSender(), signer);
      }
      if (status != Status.UNSET) revert ProtectorAlreadySet();
      _addActor(_msgSender(), protector_, _role("PROTECTOR"), Status.ACTIVE, Level.NONE);
      _ownersByProtector[protector_] = _msgSender();
    } else {
      isSignerAProtector(_msgSender(), signer);
      if (_ownersByProtector[protector_] != _msgSender()) revert NotYourProtector();
      (uint256 i, Status status) = findProtector(_msgSender(), protector_);
      if (status == Status.ACTIVE) {
        _removeActorByIndex(_msgSender(), i, _role("PROTECTOR"));
      } else {
        revert NotAnActiveProtector();
      }
      if (status != Status.ACTIVE) revert ProtectorNotFound();
      delete _ownersByProtector[protector_];
    }
    emit ProtectorUpdated(_msgSender(), protector_, active);
  }

  function isNotExpired(uint256 timestamp, uint256 validFor) public view override {
    // solhint-disable-next-line not-rely-on-time
    if (timestamp > block.timestamp || timestamp < block.timestamp - validFor) revert TimestampInvalidOrExpired();
  }

  function isSignerAProtector(address tokenOwner_, address signer_) public view override {
    if (!isProtectorFor(tokenOwner_, signer_)) revert WrongDataOrNotSignedByProtector();
  }

  function signedByProtector(address owner_, bytes32 hash, bytes memory signature) public view override returns (bool) {
    address signer = hash.recover(signature);
    (, Status status) = findProtector(owner_, signer);
    return status > Status.UNSET;
  }

  function isSignatureUsed(bytes calldata signature) public view override returns (bool) {
    return _usedSignatures[keccak256(signature)];
  }

  function checkIfSignatureUsedAndUseIfNot(bytes calldata signature) public override {
    if (_msgSender() != tokenAddress()) revert Forbidden();
    _checkIfSignatureUsedAndUseIfNot(signature);
  }

  function _checkIfSignatureUsedAndUseIfNot(bytes calldata signature) internal {
    if (_usedSignatures[keccak256(signature)]) revert SignatureAlreadyUsed();
    _usedSignatures[keccak256(signature)] = true;
  }

  function validateTimestampAndSignature(
    address tokenOwner_,
    uint256 timestamp,
    uint256 validFor,
    bytes32 hash,
    bytes calldata signature
  ) public view override {
    // solhint-disable-next-line not-rely-on-time
    if (timestamp > block.timestamp || timestamp < block.timestamp - validFor) revert TimestampInvalidOrExpired();
    if (!signedByProtector(tokenOwner_, hash, signature)) revert WrongDataOrNotSignedByProtector();
    if (isSignatureUsed(signature)) revert SignatureAlreadyUsed();
  }

  function invalidateSignatureFor(bytes32 hash, bytes calldata signature) external override onlyTokenOwner {
    address tokenOwner_ = VAULT.ownerOf(tokenId());
    (, Status status) = findProtector(tokenOwner_, _msgSender());
    if (status < Status.ACTIVE) revert NotAProtector();
    if (!signedByProtector(tokenOwner_, hash, signature)) revert WrongDataOrNotSignedByProtector();
    _usedSignatures[keccak256(signature)] = true;
  }

  // safe recipients

  function setSafeRecipient(
    address recipient,
    Level level,
    uint256 timestamp,
    uint256 validFor,
    bytes calldata signature
  ) external override onlyTokensOwner {
    if (timestamp == 0) {
      if (countActiveProtectors(_msgSender()) > 0) revert NotPermittedWhenProtectorsAreActive();
    } else {
      address signer = managerSigner.signRequest(recipient, address(0), uint256(level), timestamp, validFor, signature);

      isNotExpired(timestamp, validFor);
      isSignerAProtector(_msgSender(), signer);
      _usedSignatures[keccak256(signature)] = true;
    }
    if (level == Level.NONE) {
      _removeActor(_msgSender(), recipient, _role("RECIPIENT"));
    } else {
      _addActor(_msgSender(), recipient, _role("RECIPIENT"), Status.ACTIVE, level);
    }
    emit SafeRecipientUpdated(_msgSender(), recipient, level);
  }

  function setSignatureAsUsed(bytes calldata signature) public override {
    if (_msgSender() != tokenAddress()) revert Forbidden();
    _setSignatureAsUsed(signature);
  }

  function _setSignatureAsUsed(bytes calldata signature) internal {
    _usedSignatures[keccak256(signature)] = true;
  }

  function safeRecipientLevel(address tokenOwner_, address recipient) public view override returns (Level) {
    (, IActor.Actor memory actor) = _getActor(tokenOwner_, recipient, _role("RECIPIENT"));
    return actor.level;
  }

  function getSafeRecipients(address tokenOwner_) external view override returns (IActor.Actor[] memory) {
    return _getActors(tokenOwner_, _role("RECIPIENT"));
  }

  // beneficiaries

  function setBeneficiary(
    address beneficiary,
    Status status,
    uint256 timestamp,
    uint256 validFor,
    bytes calldata signature
  ) external override onlyTokensOwner {
    if (timestamp == 0) {
      if (countActiveProtectors(_msgSender()) > 0) revert NotPermittedWhenProtectorsAreActive();
    } else {
      address signer = managerSigner.signRequest(beneficiary, address(0), uint256(status), timestamp, validFor, signature);
      isNotExpired(timestamp, validFor);
      isSignerAProtector(_msgSender(), signer);
      _usedSignatures[keccak256(signature)] = true;
    }
    if (status == Status.UNSET) {
      _removeActor(_msgSender(), beneficiary, _role("BENEFICIARY"));
    } else {
      _addActor(_msgSender(), beneficiary, _role("BENEFICIARY"), status, Level.NONE);
    }
    emit BeneficiaryUpdated(_msgSender(), beneficiary, status);
  }

  function configureBeneficiary(uint256 quorum, uint256 proofOfLifeDurationInDays) external onlyTokensOwner {
    if (countActiveProtectors(_msgSender()) > 0) revert NotPermittedWhenProtectorsAreActive();
    if (quorum == 0) revert QuorumCannotBeZero();
    if (quorum > _countActiveActorsByRole(_msgSender(), _role("BENEFICIARY"))) revert QuorumCannotBeGreaterThanBeneficiaries();
    // solhint-disable-next-line not-rely-on-time
    _beneficiaryConfs[_msgSender()] = BeneficiaryConf(quorum, proofOfLifeDurationInDays, block.timestamp);
    delete _beneficiariesRequests[_msgSender()];
  }

  function getBeneficiaries(address tokenOwner_) external view returns (IActor.Actor[] memory, BeneficiaryConf memory) {
    return (_getActors(tokenOwner_, _role("BENEFICIARY")), _beneficiaryConfs[tokenOwner_]);
  }

  function proofOfLife() external onlyTokensOwner {
    if (_beneficiaryConfs[_msgSender()].proofOfLifeDurationInDays == 0) revert BeneficiaryNotConfigured();
    // solhint-disable-next-line not-rely-on-time
    _beneficiaryConfs[_msgSender()].lastProofOfLife = block.timestamp;
    delete _beneficiariesRequests[_msgSender()];
  }

  function _hasApproved(address tokenOwner_) internal view returns (bool) {
    for (uint256 i = 0; i < _beneficiariesRequests[tokenOwner_].approvers.length; i++) {
      if (_msgSender() == _beneficiariesRequests[tokenOwner_].approvers[i]) {
        return true;
      }
    }
    return false;
  }

  function requestTransfer(address tokenOwner_, address beneficiaryRecipient) external {
    if (beneficiaryRecipient == address(0)) revert NoZeroAddress();
    if (_beneficiaryConfs[tokenOwner_].proofOfLifeDurationInDays == 0) revert BeneficiaryNotConfigured();
    (, IActor.Actor storage actor) = _getActor(tokenOwner_, _msgSender(), _role("BENEFICIARY"));
    if (actor.status == Status.UNSET) revert NotABeneficiary();
    if (
      _beneficiaryConfs[tokenOwner_].lastProofOfLife + (_beneficiaryConfs[tokenOwner_].proofOfLifeDurationInDays * 1 hours) >
      // solhint-disable-next-line not-rely-on-time
      block.timestamp
    ) revert NotExpiredYet();
    // the following prevents hostile beneficiaries from blocking the process not allowing them to reset the recipient
    if (_hasApproved(tokenOwner_)) revert RequestAlreadyApproved();
    // a beneficiary is proposing a new recipient
    if (_beneficiariesRequests[tokenOwner_].recipient != beneficiaryRecipient) {
      // solhint-disable-next-line not-rely-on-time
      if (block.timestamp - _beneficiariesRequests[tokenOwner_].startedAt > 30 days) {
        // reset the request
        delete _beneficiariesRequests[tokenOwner_];
      } else revert InconsistentRecipient();
    }
    if (_beneficiariesRequests[tokenOwner_].recipient == address(0)) {
      _beneficiariesRequests[tokenOwner_].recipient = beneficiaryRecipient;
      // solhint-disable-next-line not-rely-on-time
      _beneficiariesRequests[tokenOwner_].startedAt = block.timestamp;
      _beneficiariesRequests[tokenOwner_].approvers.push(_msgSender());
    } else if (!_hasApproved(_msgSender())) {
      _beneficiariesRequests[tokenOwner_].approvers.push(_msgSender());
    }
  }

  function inherit(address tokenOwner_) external {
    if (
      _beneficiariesRequests[tokenOwner_].recipient == _msgSender() &&
      _beneficiariesRequests[tokenOwner_].approvers.length >= _beneficiaryConfs[tokenOwner_].quorum
    ) {
      VAULT.managedTransfer(tokenId(), _msgSender());
      emit Inherited(tokenAddress(), tokenId(), tokenOwner_, _msgSender());
      delete _beneficiariesRequests[tokenOwner_];
    } else revert Unauthorized();
  }

  /**
   * @dev This empty reserved space is put in place to allow future versions to add new
   * variables without shifting down storage in the inheritance chain.
   * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
   */
  uint256[50] private __gap;
}
