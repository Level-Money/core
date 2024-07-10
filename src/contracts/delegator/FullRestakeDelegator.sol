// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.25;

import {BaseDelegator} from "./BaseDelegator.sol";

import {IFullRestakeDelegator} from "src/interfaces/delegator/IFullRestakeDelegator.sol";
import {IBaseDelegator} from "src/interfaces/delegator/IBaseDelegator.sol";
import {IVault} from "src/interfaces/vault/IVault.sol";
import {IFullRestakeDelegatorHook} from "src/interfaces/delegator/hook/IFullRestakeDelegatorHook.sol";

import {Checkpoints} from "src/contracts/libraries/Checkpoints.sol";

import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract FullRestakeDelegator is BaseDelegator, IFullRestakeDelegator {
    using Checkpoints for Checkpoints.Trace256;
    using Math for uint256;

    /**
     * @inheritdoc IFullRestakeDelegator
     */
    bytes32 public constant NETWORK_LIMIT_SET_ROLE = keccak256("NETWORK_LIMIT_SET_ROLE");

    /**
     * @inheritdoc IFullRestakeDelegator
     */
    bytes32 public constant OPERATOR_NETWORK_LIMIT_SET_ROLE = keccak256("OPERATOR_NETWORK_LIMIT_SET_ROLE");

    mapping(address network => Checkpoints.Trace256 value) private _networkLimit;

    mapping(address network => Checkpoints.Trace256 value) private _totalOperatorNetworkLimit;

    mapping(address network => mapping(address operator => Checkpoints.Trace256 value)) private _operatorNetworkLimit;

    constructor(
        address networkRegistry,
        address vaultFactory,
        address operatorVaultOptInService,
        address operatorNetworkOptInService,
        address delegatorFactory,
        uint64 entityType
    )
        BaseDelegator(
            networkRegistry,
            vaultFactory,
            operatorVaultOptInService,
            operatorNetworkOptInService,
            delegatorFactory,
            entityType
        )
    {}

    /**
     * @inheritdoc IFullRestakeDelegator
     */
    function networkLimitAt(address network, uint48 timestamp) public view returns (uint256) {
        return _networkLimit[network].upperLookupRecent(timestamp);
    }

    /**
     * @inheritdoc IFullRestakeDelegator
     */
    function networkLimit(address network) public view returns (uint256) {
        return _networkLimit[network].latest();
    }

    /**
     * @inheritdoc IFullRestakeDelegator
     */
    function totalOperatorNetworkLimitAt(address network, uint48 timestamp) public view returns (uint256) {
        return _totalOperatorNetworkLimit[network].upperLookupRecent(timestamp);
    }

    /**
     * @inheritdoc IFullRestakeDelegator
     */
    function totalOperatorNetworkLimit(address network) public view returns (uint256) {
        return _totalOperatorNetworkLimit[network].latest();
    }

    /**
     * @inheritdoc IFullRestakeDelegator
     */
    function operatorNetworkLimitAt(
        address network,
        address operator,
        uint48 timestamp
    ) public view returns (uint256) {
        return _operatorNetworkLimit[network][operator].upperLookupRecent(timestamp);
    }

    /**
     * @inheritdoc IFullRestakeDelegator
     */
    function operatorNetworkLimit(address network, address operator) public view returns (uint256) {
        return _operatorNetworkLimit[network][operator].latest();
    }

    /**
     * @inheritdoc IBaseDelegator
     */
    function networkStakeAt(
        address network,
        uint48 timestamp
    ) external view override(BaseDelegator, IBaseDelegator) returns (uint256) {
        return Math.min(
            IVault(vault).activeSupplyAt(timestamp),
            Math.min(networkLimitAt(network, timestamp), totalOperatorNetworkLimitAt(network, timestamp))
        );
    }

    /**
     * @inheritdoc IBaseDelegator
     */
    function networkStake(address network) external view override(BaseDelegator, IBaseDelegator) returns (uint256) {
        return
            Math.min(IVault(vault).activeSupply(), Math.min(networkLimit(network), totalOperatorNetworkLimit(network)));
    }

    /**
     * @inheritdoc IFullRestakeDelegator
     */
    function setNetworkLimit(address network, uint256 amount) external onlyRole(NETWORK_LIMIT_SET_ROLE) {
        if (amount > maxNetworkLimit[network]) {
            revert ExceedsMaxNetworkLimit();
        }

        _setNetworkLimit(network, amount);

        emit SetNetworkLimit(network, amount);
    }

    /**
     * @inheritdoc IFullRestakeDelegator
     */
    function setOperatorNetworkLimit(
        address network,
        address operator,
        uint256 amount
    ) external onlyRole(OPERATOR_NETWORK_LIMIT_SET_ROLE) {
        _setOperatorNetworkLimit(network, operator, amount);

        emit SetOperatorNetworkLimit(network, operator, amount);
    }

    function _setNetworkLimit(address network, uint256 amount) internal {
        _networkLimit[network].push(Time.timestamp(), amount);
    }

    function _setOperatorNetworkLimit(address network, address operator, uint256 amount) internal {
        _totalOperatorNetworkLimit[network].push(
            Time.timestamp(), totalOperatorNetworkLimit(network) - operatorNetworkLimit(network, operator) + amount
        );
        _operatorNetworkLimit[network][operator].push(Time.timestamp(), amount);
    }

    function _stakeAt(address network, address operator, uint48 timestamp) internal view override returns (uint256) {
        return Math.min(
            IVault(vault).activeSupplyAt(timestamp),
            Math.min(networkLimitAt(network, timestamp), operatorNetworkLimitAt(network, operator, timestamp))
        );
    }

    function _stake(address network, address operator) internal view override returns (uint256) {
        return Math.min(
            IVault(vault).activeSupply(), Math.min(networkLimit(network), operatorNetworkLimit(network, operator))
        );
    }

    function _setMaxNetworkLimit(uint256 amount) internal override {
        (bool exists,, uint256 latestValue) = _networkLimit[msg.sender].latestCheckpoint();
        if (exists) {
            _networkLimit[msg.sender].push(Time.timestamp(), Math.min(latestValue, amount));
        }
    }

    function _onSlash(
        address network,
        address operator,
        uint256 slashedAmount,
        uint48 captureTimestamp
    ) internal override {
        if (hook != address(0)) {
            (bool success, bytes memory returndata) = hook.call{gas: 200_000}(
                abi.encodeWithSelector(
                    IFullRestakeDelegatorHook.onSlash.selector, network, operator, slashedAmount, captureTimestamp
                )
            );
            if (success && returndata.length == 96) {
                (bool isUpdate, uint256 networkLimit_, uint256 operatorNetworkLimit_) =
                    abi.decode(returndata, (bool, uint256, uint256));
                if (isUpdate) {
                    _setNetworkLimit(network, networkLimit_);
                    _setOperatorNetworkLimit(network, operator, operatorNetworkLimit_);
                }
            }
        }
    }

    function _initializeInternal(
        address,
        bytes memory data
    ) internal override returns (IBaseDelegator.BaseParams memory) {
        InitParams memory params = abi.decode(data, (InitParams));

        if (
            params.baseParams.defaultAdminRoleHolder == address(0)
                && (
                    params.networkLimitSetRoleHolder == address(0) || params.operatorNetworkLimitSetRoleHolder == address(0)
                )
        ) {
            revert MissingRoleHolders();
        }

        if (params.networkLimitSetRoleHolder != address(0)) {
            _grantRole(NETWORK_LIMIT_SET_ROLE, params.networkLimitSetRoleHolder);
        }
        if (params.operatorNetworkLimitSetRoleHolder != address(0)) {
            _grantRole(OPERATOR_NETWORK_LIMIT_SET_ROLE, params.operatorNetworkLimitSetRoleHolder);
        }

        return params.baseParams;
    }
}
