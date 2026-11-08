// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {Freelancer} from "../src/Freelancer.sol";

contract FreelancerScript is Script {
    Freelancer public freelancer;

    function setUp() public {}

    function run() public {

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address initialOwner = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        freelancer = new Freelancer(initialOwner);

        vm.stopBroadcast();
    }
}