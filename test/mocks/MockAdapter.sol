// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {IAdapter} from "randcast-user-contract/interfaces/IAdapter.sol";

contract MockAdapter is IAdapter {
    uint64 public nextSubId = 1;

    function createSubscription() external returns (uint64) {
        return nextSubId++;
    }

    function fundSubscription(uint64) external payable {}

    function addConsumer(uint64, address) external {}

    function removeConsumer(uint64, address) external {}

    function cancelSubscription(uint64, address) external {}

    function setReferral(uint64, uint64) external {}

    function nodeWithdrawETH(address, uint256) external {}

    function requestRandomness(
        RandomnessRequestParams calldata
    ) external pure returns (bytes32) {
        return bytes32(0);
    }

    function fulfillRandomness(
        uint32 groupIndex,
        bytes32 requestId,
        uint256 signature,
        RequestDetail calldata requestDetail,
        PartialSignature[] calldata partialSignatures
    ) external {}

    function cancelOvertimeRequest(bytes32, RequestDetail calldata) external {}

    function getLastSubscription(address) external pure returns (uint64) {
        return 0;
    }

    function getPendingRequestCommitment(
        bytes32
    ) external pure returns (bytes32) {
        return bytes32(0);
    }

    function getLastAssignedGroupIndex() external pure returns (uint256) {
        return 0;
    }

    function getLastRandomness() external pure returns (uint256) {
        return 0;
    }

    function getRandomnessCount() external pure returns (uint256) {
        return 0;
    }

    function getCurrentSubId() external pure returns (uint64) {
        return 0;
    }

    function getCumulativeData()
        external
        pure
        returns (uint256, uint256, uint256)
    {
        return (0, 0, 0);
    }

    function getController() external pure returns (address) {
        return address(0);
    }

    function getSubscription(
        uint64
    )
        external
        pure
        returns (
            address,
            address[] memory,
            uint256,
            uint256,
            uint64,
            uint64,
            uint64,
            uint64,
            uint256
        )
    {
        return (address(0), new address[](0), 1 ether, 0, 0, 0, 0, 0, 0);
    }

    function getAdapterConfig()
        external
        pure
        returns (uint16, uint32, uint32, uint32, uint256, uint256, uint256)
    {
        return (3, 0, 0, 0, 0, 0, 0);
    }

    function estimatePaymentAmountInETH(
        uint32,
        uint32,
        uint32,
        uint256,
        uint32
    ) external pure returns (uint256) {
        return 0.01 ether;
    }

    function getFeeTier(uint64) external pure returns (uint32) {
        return 0;
    }

    function getReferralConfig() external pure returns (bool, uint16, uint16) {
        return (false, 0, 0);
    }

    function getFlatFeeConfig()
        external
        pure
        returns (
            uint32,
            uint32,
            uint32,
            uint32,
            uint32,
            uint24,
            uint24,
            uint24,
            uint24,
            uint16,
            bool,
            uint256,
            uint256
        )
    {
        return (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, false, 0, 0);
    }
}
