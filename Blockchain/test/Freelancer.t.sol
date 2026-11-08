// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Freelancer} from "../src/Freelancer.sol";

/// @dev Freelancer-side contract used to test reentrancy and ETH-rejecting wallets.
contract MaliciousFreelancer {
    Freelancer public f;
    uint256 public reentryAttempts;
    bool public reenterSucceeded;
    bool public rejectEther;

    constructor(Freelancer _f) {
        f = _f;
    }

    function register() external {
        f.registerFreelancerProfile("Mallory", 1, 1);
    }

    function applyFor(uint256 fid, uint256 eid, uint256 jid) external {
        f.applyForJob(fid, eid, jid);
    }

    function submit(uint256 eid, uint256 jid) external {
        f.submitWork(eid, jid);
    }

    function doWithdraw() external {
        f.withdraw();
    }

    function setReject(bool r) external {
        rejectEther = r;
    }

    receive() external payable {
        if (rejectEther) revert("no ether");
        reentryAttempts++;
        try f.withdraw() {
            reenterSucceeded = true;
        } catch {}
    }
}

contract FreelancerTest is Test {
    Freelancer f;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");       // freelancer id 0
    address carol = makeAddr("carol");       // freelancer id 1
    address bob = makeAddr("bob");           // employer id 0
    address stranger = makeAddr("stranger");

    uint256 constant PRICE = 1 ether;
    uint256 constant DURATION = 1 days;

    // events (redeclared so expectEmit can match them)
    event JobCreated(uint256 indexed employerId, uint256 indexed jobId, uint256 price, uint256 durationInSeconds);
    event FreelancerHired(uint256 indexed employerId, uint256 indexed jobId, uint256 indexed freelancerId, uint256 deadline);
    event JobPaid(uint256 indexed employerId, uint256 indexed jobId, uint256 toFreelancer, uint256 refundedToEmployer, uint256 fee);
    event Withdrawn(address indexed account, uint256 amount);

    function setUp() public {
        f = new Freelancer(owner);
        vm.deal(bob, 100 ether);

        vm.prank(alice);
        f.registerFreelancerProfile("Alice", 3, 1000);
        vm.prank(carol);
        f.registerFreelancerProfile("Carol", 5, 2000);
        vm.prank(bob);
        f.registerEmployerProfile("Bob Inc");
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------
    function _create() internal returns (uint256 jobId) {
        jobId = f.getNumberOfCreatedJobList(0);
        vm.prank(bob);
        f.createjobListing{value: PRICE}(
            0,
            Freelancer.CreateJobListingInput("Logo", "Design a logo", DURATION, PRICE)
        );
    }

    function _apply(uint256 fid, address who, uint256 jobId) internal {
        vm.prank(who);
        f.applyForJob(fid, 0, jobId);
    }

    function _hire(uint256 fid, uint256 jobId) internal {
        vm.prank(bob);
        f.hireFreelancer(0, fid, jobId);
    }

    function _submit(address who, uint256 jobId) internal {
        vm.prank(who);
        f.submitWork(0, jobId);
    }

    function _release(uint256 jobId) internal {
        vm.prank(bob);
        f.releaseEscrowPayment(0, jobId);
    }

    /// Job created, alice applied and hired.
    function _inProgress() internal returns (uint256 jobId) {
        jobId = _create();
        _apply(0, alice, jobId);
        _hire(0, jobId);
    }

    /// Alice submitted on time.
    function _submittedOnTime() internal returns (uint256 jobId) {
        jobId = _inProgress();
        _submit(alice, jobId);
    }

    function _status(uint256 jobId) internal view returns (Freelancer.Status) {
        return f.getJob(0, jobId).status;
    }

    function _notInStatus(uint256 jobId, Freelancer.Status s) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Freelancer.Freelancer_JobNotInStatus.selector, jobId, s);
    }

    // ------------------------------------------------------------------
    // Constructor / ownership
    // ------------------------------------------------------------------
    function test_Constructor_SetsOwner() public view {
        assertEq(f.owner(), owner);
    }

    function test_Constructor_RevertsOnZeroOwner() public {
        vm.expectRevert(Freelancer.Freelancer_InvalidAddress.selector);
        new Freelancer(address(0));
    }

    function test_Ownership_TwoStepTransfer() public {
        vm.prank(owner);
        f.transferOwnership(stranger);
        assertEq(f.owner(), owner); // not changed yet
        assertEq(f.pendingOwner(), stranger);

        vm.prank(stranger);
        f.acceptOwnership();
        assertEq(f.owner(), stranger);
        assertEq(f.pendingOwner(), address(0));
    }

    function test_Ownership_OnlyOwnerCanStart() public {
        vm.prank(stranger);
        vm.expectRevert(Freelancer.Freelancer_NotAuthorisedOwner.selector);
        f.transferOwnership(stranger);
    }

    function test_Ownership_ZeroAddressReverts() public {
        vm.prank(owner);
        vm.expectRevert(Freelancer.Freelancer_InvalidAddress.selector);
        f.transferOwnership(address(0));
    }

    function test_Ownership_OnlyPendingOwnerCanAccept() public {
        vm.prank(owner);
        f.transferOwnership(stranger);

        vm.prank(carol);
        vm.expectRevert(Freelancer.Freelancer_NotPendingOwner.selector);
        f.acceptOwnership();
    }

    // ------------------------------------------------------------------
    // Registration
    // ------------------------------------------------------------------
    function test_RegisterFreelancer_StoresProfile() public view {
        Freelancer.FreelancerProfile memory p = f.getFreelancerProfile(0);
        assertEq(p.id, 0);
        assertEq(p.name, "Alice");
        assertEq(p.wallet, alice);
        assertEq(p.experienceYears, 3);
        assertEq(p.hourlyRateInWei, 1000);
        assertTrue(p.isAvailableHire);

        assertEq(f.freelancerIdToAddress(0), alice);
        assertEq(f.freelancerIdByAddress(carol), 1);
        assertTrue(f.freelancerRegistered(alice));
        assertEq(f.getNumberOfRegisteredFreeLancers(), 2);
    }

    function test_RegisterFreelancer_DuplicateReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Freelancer.Freelancer_AlreadyRegistered.selector, alice));
        f.registerFreelancerProfile("Again", 1, 1);
    }

    function test_RegisterFreelancer_EmptyNameReverts() public {
        vm.prank(stranger);
        vm.expectRevert(Freelancer.Freelancer_EmptyName.selector);
        f.registerFreelancerProfile("", 1, 1);
    }

    function test_RegisterEmployer_StoresProfile() public view {
        Freelancer.EmployerProfile memory p = f.getEmployerProfile(0);
        assertEq(p.name, "Bob Inc");
        assertEq(p.wallet, bob);
        assertFalse(p.isHiring);
        assertEq(f.employerIdToAddress(0), bob);
        assertEq(f.employerIdByAddress(bob), 0);
        assertTrue(f.employerRegistered(bob));
    }

    function test_RegisterEmployer_DuplicateReverts() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Freelancer.Freelancer_AlreadyRegistered.selector, bob));
        f.registerEmployerProfile("Again");
    }

    function test_RegisterEmployer_EmptyNameReverts() public {
        vm.prank(stranger);
        vm.expectRevert(Freelancer.Freelancer_EmptyName.selector);
        f.registerEmployerProfile("");
    }

    // ------------------------------------------------------------------
    // createjobListing
    // ------------------------------------------------------------------
    function test_CreateJob_EscrowsFundsAndStoresJob() public {
        vm.expectEmit(true, true, false, true);
        emit JobCreated(0, 0, PRICE, DURATION);
        uint256 jobId = _create();

        assertEq(jobId, 0);
        assertEq(address(f).balance, PRICE);

        Freelancer.JobListing memory j = f.getJob(0, 0);
        assertEq(j.title, "Logo");
        assertEq(j.fixedPriceInWei, PRICE);
        assertEq(j.durationInSeconds, DURATION);
        assertEq(j.deadlineTimestamp, 0); // starts when hired
        assertTrue(j.status == Freelancer.Status.Open);

        assertEq(f.openJobCount(0), 1);
        assertTrue(f.getEmployerProfile(0).isHiring);
    }

    function test_CreateJob_WrongValueReverts() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Freelancer.Freelancer_IncorrectjobCreationFee.selector, PRICE, 0));
        f.createjobListing(0, Freelancer.CreateJobListingInput("Logo", "d", DURATION, PRICE));
    }

    function test_CreateJob_ZeroPriceReverts() public {
        vm.prank(bob);
        vm.expectRevert(Freelancer.Freelancer_InvalidJobInput.selector);
        f.createjobListing(0, Freelancer.CreateJobListingInput("Logo", "d", DURATION, 0));
    }

    function test_CreateJob_ZeroDurationReverts() public {
        vm.prank(bob);
        vm.expectRevert(Freelancer.Freelancer_InvalidJobInput.selector);
        f.createjobListing{value: PRICE}(0, Freelancer.CreateJobListingInput("Logo", "d", 0, PRICE));
    }

    function test_CreateJob_EmptyTitleReverts() public {
        vm.prank(bob);
        vm.expectRevert(Freelancer.Freelancer_InvalidJobInput.selector);
        f.createjobListing{value: PRICE}(0, Freelancer.CreateJobListingInput("", "d", DURATION, PRICE));
    }

    function test_CreateJob_NonEmployerReverts() public {
        vm.deal(stranger, 10 ether);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Freelancer.Freelancer_UnauthorizedEmployer.selector, 0, stranger));
        f.createjobListing{value: PRICE}(0, Freelancer.CreateJobListingInput("Logo", "d", DURATION, PRICE));
    }

    function test_CreateJob_UnknownEmployerIdReverts() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Freelancer.Freelancer_UnauthorizedEmployer.selector, 7, bob));
        f.createjobListing{value: PRICE}(7, Freelancer.CreateJobListingInput("Logo", "d", DURATION, PRICE));
    }

    // ------------------------------------------------------------------
    // cancelJob
    // ------------------------------------------------------------------
    function test_CancelJob_RefundsEmployer() public {
        uint256 jobId = _create();

        vm.prank(bob);
        f.cancelJob(0, jobId);

        assertTrue(_status(jobId) == Freelancer.Status.Cancelled);
        assertEq(f.pendingWithdrawals(bob), PRICE);
        assertEq(f.openJobCount(0), 0);
        assertFalse(f.getEmployerProfile(0).isHiring);

        uint256 before = bob.balance;
        vm.prank(bob);
        f.withdraw();
        assertEq(bob.balance, before + PRICE);
        assertEq(address(f).balance, 0);
    }

    function test_CancelJob_AfterHireReverts() public {
        uint256 jobId = _inProgress();
        vm.prank(bob);
        vm.expectRevert(_notInStatus(jobId, Freelancer.Status.InProgress));
        f.cancelJob(0, jobId);
    }

    function test_CancelJob_TwiceReverts() public {
        uint256 jobId = _create();
        vm.startPrank(bob);
        f.cancelJob(0, jobId);
        vm.expectRevert(_notInStatus(jobId, Freelancer.Status.Cancelled));
        f.cancelJob(0, jobId);
        vm.stopPrank();
    }

    function test_CancelJob_NonEmployerReverts() public {
        uint256 jobId = _create();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Freelancer.Freelancer_UnauthorizedEmployer.selector, 0, stranger));
        f.cancelJob(0, jobId);
    }

    // ------------------------------------------------------------------
    // applyForJob
    // ------------------------------------------------------------------
    function test_Apply_RecordsApplication() public {
        uint256 jobId = _create();
        _apply(0, alice, jobId);
        assertTrue(f.hasApplied(0, jobId, 0));
        assertFalse(f.hasApplied(0, jobId, 1));
    }

    function test_Apply_DuplicateReverts() public {
        uint256 jobId = _create();
        _apply(0, alice, jobId);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Freelancer.Freelancer_AlreadyApplied.selector, 0, jobId));
        f.applyForJob(0, 0, jobId);
    }

    
}
