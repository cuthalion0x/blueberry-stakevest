// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";
import {BlueberryStaking} from "../src/BlueberryStaking.sol";
import {BlueberryToken} from "../src/BlueberryToken.sol";
import {MockbToken} from "./mocks/MockbToken.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract Control is Test {
    BlueberryStaking blueberryStaking;
    BlueberryToken blb;
    IERC20 mockbToken1;
    IERC20 mockbToken2;
    IERC20 mockbToken3;

    IERC20 mockUSDC;

    address public treasury = address(0x1);
    address public owner = address(3);

    address[] public existingBTokens;

    // Initialize the contract and deploy necessary instances
    function setUp() public {
        vm.startPrank(owner);
        // Deploy mock tokens and BlueberryToken
        mockbToken1 = new MockbToken();
        mockbToken2 = new MockbToken();
        mockbToken3 = new MockbToken();
        mockUSDC = new MockUSDC();
        blb = new BlueberryToken(address(this), owner, block.timestamp + 30);

        // Initialize existingBTokens array
        existingBTokens = new address[](3);

        // Assign addresses of mock tokens to existingBTokens array
        existingBTokens[0] = address(mockbToken1);
        existingBTokens[1] = address(mockbToken2);
        existingBTokens[2] = address(mockbToken3);

        // Deploy BlueberryStaking contract and transfer BLB tokens
        blueberryStaking = new BlueberryStaking();

        blueberryStaking.initialize(address(blb), address(mockUSDC), address(treasury), 1_209_600, existingBTokens, owner);

        skip(300);
        blb.mint(address(blueberryStaking), 1e18);
        console2.log(blueberryStaking.owner());
    }

    // Test setting the vesting length
    function testSetVestLength() public {
        vm.startPrank(owner);
        blueberryStaking.setVestLength(69_420);
        assertEq(blueberryStaking.vestLength(), 69_420);
    }

    // Test setting the reward duration
    function testSetRewardDuration() public {
        vm.startPrank(owner);
        blueberryStaking.setRewardDuration(5_318_008);
        assertEq(blueberryStaking.rewardDuration(), 5_318_008);
    }

    // Test adding new bTokens to the contract
    function testaddIbTokens() public {
        vm.startPrank(owner);
        // Deploy new mock tokens
        IERC20 mockbToken4 = new MockbToken();
        IERC20 mockbToken5 = new MockbToken();
        IERC20 mockbToken6 = new MockbToken();

        // Create an array of addresses representing the new bTokens
        address[] memory bTokens = new address[](3);
        bTokens[0] = address(mockbToken4);
        bTokens[1] = address(mockbToken5);
        bTokens[2] = address(mockbToken6);

        // Add the new bTokens to the BlueberryStaking contract
        blueberryStaking.addIbTokens(bTokens);

        // Check if the new bTokens were added successfully
        assertEq(blueberryStaking.isIbToken(address(mockbToken4)), true);
        assertEq(blueberryStaking.isIbToken(address(mockbToken5)), true);
        assertEq(blueberryStaking.isIbToken(address(mockbToken6)), true);
    }

    // Test removing existing bTokens from the contract
    function testremoveIbTokens() public {
        vm.startPrank(owner);
        // Check if existing bTokens are initially present
        assertEq(blueberryStaking.isIbToken(address(existingBTokens[0])), true);
        assertEq(blueberryStaking.isIbToken(address(existingBTokens[1])), true);
        assertEq(blueberryStaking.isIbToken(address(existingBTokens[2])), true);

        // Remove existing bTokens from the BlueberryStaking contract
        blueberryStaking.removeIbTokens(existingBTokens);

        // Check if existing bTokens were removed successfully
        assertEq(blueberryStaking.isIbToken(address(existingBTokens[0])), false);
        assertEq(blueberryStaking.isIbToken(address(existingBTokens[1])), false);
        assertEq(blueberryStaking.isIbToken(address(existingBTokens[2])), false);
    }

    // Test pausing and unpausing the BlueberryStaking contract
    function testPausing() public {
        vm.startPrank(owner);
        // Pause the contract and verify the paused state
        blueberryStaking.pause();
        assertEq(blueberryStaking.paused(), true);

        // Unpause the contract and verify the resumed state
        blueberryStaking.unpause();
        assertEq(blueberryStaking.paused(), false);
    }

    // Test notifying reward amounts for existing bTokens
    function testmodifyRewardAmount() public {
        // Set reward amounts for existing bTokens
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1e19;
        amounts[1] = 1e19 * 4;
        amounts[2] = 1e23 * 4;
        blueberryStaking.modifyRewardAmount(existingBTokens, amounts);

        // Check if the reward rates were set correctly
        assertEq(
            blueberryStaking.rewardRate(existingBTokens[0]),
            1e19 / blueberryStaking.rewardDuration()
        );
        assertEq(
            blueberryStaking.rewardRate(existingBTokens[1]),
            (1e19 * 4) / blueberryStaking.rewardDuration()
        );
        assertEq(
            blueberryStaking.rewardRate(existingBTokens[2]),
            (1e23 * 4) / blueberryStaking.rewardDuration()
        );
    }

    // Test changing the epoch length
    function testChangeEpochLength() public {
        vm.startPrank(owner);

        // Change the epoch length and verify the updated value
        blueberryStaking.changeEpochLength(70_420_248_412);
        assertEq(blueberryStaking.epochLength(), 70_420_248_412);
    }

    // Test changing the BLB token address
    function testChangeBLB() public {
        vm.startPrank(owner);

        // Deploy a new BLB token
        BlueberryToken newBLB = new BlueberryToken(
            address(this),
            address(this),
            block.timestamp + 30
        );

        // Change the BLB token address to the new BLB contract
        blueberryStaking.changeBLB(address(newBLB));

        // Check if the BLB token address was updated correctly
        assertEq(address(blueberryStaking.blb()), address(newBLB));
    }
}
