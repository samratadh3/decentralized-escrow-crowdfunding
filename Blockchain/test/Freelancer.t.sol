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

    function test_Apply_WrongCallerReverts() public {
        uint256 jobId = _create();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Freelancer.Freelancer_UnauthorizedFreelancer.selector, 0, stranger));
        f.applyForJob(0, 0, jobId);
    }

    function test_Apply_ImpersonatingOtherFreelancerIdReverts() public {
        uint256 jobId = _create();
        vm.prank(carol); // carol is id 1, tries to apply as id 0
        vm.expectRevert(abi.encodeWithSelector(Freelancer.Freelancer_UnauthorizedFreelancer.selector, 0, carol));
        f.applyForJob(0, 0, jobId);
    }

    function test_Apply_InvalidJobIdReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Freelancer.Freelancer_InvalidJobId.selector, 0, 99));
        f.applyForJob(0, 0, 99);
    }

    function test_Apply_ClosedJobReverts() public {
        uint256 jobId = _inProgress();
        vm.prank(carol);
        vm.expectRevert(_notInStatus(jobId, Freelancer.Status.InProgress));
        f.applyForJob(1, 0, jobId);
    }

    // ------------------------------------------------------------------
    // hireFreelancer
    // ------------------------------------------------------------------
    function test_Hire_SetsStateAndDeadline() public {
        uint256 jobId = _create();
        _apply(0, alice, jobId);

        vm.warp(1_000_000);
        vm.expectEmit(true, true, true, true);
        emit FreelancerHired(0, jobId, 0, 1_000_000 + DURATION);
        _hire(0, jobId);

        Freelancer.JobListing memory j = f.getJob(0, jobId);
        assertTrue(j.status == Freelancer.Status.InProgress);
        assertEq(j.hiredFreelancerId, 0);
        assertEq(j.deadlineTimestamp, 1_000_000 + DURATION);
        assertFalse(f.getFreelancerProfile(0).isAvailableHire);
        assertFalse(f.getEmployerProfile(0).isHiring);
    }

    function test_Hire_WithoutApplicationReverts() public {
        uint256 jobId = _create();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Freelancer.Freelancer_NotApplied.selector, 0, jobId));
        f.hireFreelancer(0, 0, jobId);
    }

    function test_Hire_UnregisteredFreelancerIdReverts() public {
        uint256 jobId = _create();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Freelancer.Freelancer_UnauthorizedFreelancer.selector, 42, bob));
        f.hireFreelancer(0, 42, jobId);
    }

    function test_Hire_BusyFreelancerReverts() public {
        _inProgress(); // alice busy on job 0
        uint256 job2 = _create();
        _apply(0, alice, job2);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Freelancer.Freelancer_FreelancerUnavailable.selector, 0));
        f.hireFreelancer(0, 0, job2);
    }

    function test_Hire_NonEmployerReverts() public {
        uint256 jobId = _create();
        _apply(0, alice, jobId);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Freelancer.Freelancer_UnauthorizedEmployer.selector, 0, stranger));
        f.hireFreelancer(0, 0, jobId);
    }

    function test_Hire_AlreadyHiredJobReverts() public {
        uint256 jobId = _inProgress();
        vm.prank(bob);
        vm.expectRevert(_notInStatus(jobId, Freelancer.Status.InProgress));
        f.hireFreelancer(0, 1, jobId);
    }

    // ------------------------------------------------------------------
    // submitWork
    // ------------------------------------------------------------------
    function test_Submit_SetsStatusAndTimestamp() public {
        uint256 jobId = _inProgress();
        vm.warp(block.timestamp + 100);
        _submit(alice, jobId);

        Freelancer.JobListing memory j = f.getJob(0, jobId);
        assertTrue(j.status == Freelancer.Status.Submitted);
        assertEq(j.submittedAt, block.timestamp);
    }

    function test_Submit_NonHiredFreelancerReverts() public {
        uint256 jobId = _inProgress();
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(Freelancer.Freelancer_UnauthorizedFreelancer.selector, 0, carol));
        f.submitWork(0, jobId);
    }

    function test_Submit_EmployerCannotSubmit() public {
        uint256 jobId = _inProgress();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Freelancer.Freelancer_UnauthorizedFreelancer.selector, 0, bob));
        f.submitWork(0, jobId);
    }

    function test_Submit_OpenJobReverts() public {
        uint256 jobId = _create();
        vm.prank(alice);
        vm.expectRevert(_notInStatus(jobId, Freelancer.Status.Open));
        f.submitWork(0, jobId);
    }

    function test_Submit_TwiceReverts() public {
        uint256 jobId = _submittedOnTime();
        vm.prank(alice);
        vm.expectRevert(_notInStatus(jobId, Freelancer.Status.Submitted));
        f.submitWork(0, jobId);
    }

    // ------------------------------------------------------------------
    // releaseEscrowPayment + late penalty
    // ------------------------------------------------------------------
    function test_Release_OnTime_FullPayment() public {
        uint256 jobId = _submittedOnTime();

        vm.expectEmit(true, true, false, true);
        emit JobPaid(0, jobId, PRICE, 0, 0);
        _release(jobId);

        assertTrue(_status(jobId) == Freelancer.Status.Paid);
        assertEq(f.pendingWithdrawals(alice), PRICE);
        assertEq(f.pendingWithdrawals(bob), 0);
        assertTrue(f.getFreelancerProfile(0).isAvailableHire);

        uint256 before = alice.balance;
        vm.prank(alice);
        f.withdraw();
        assertEq(alice.balance, before + PRICE);
        assertEq(address(f).balance, 0);
    }

    function test_Release_SubmittedExactlyAtDeadline_NoPenalty() public {
        uint256 jobId = _inProgress();
        vm.warp(f.getJob(0, jobId).deadlineTimestamp);
        _submit(alice, jobId);
        _release(jobId);
        assertEq(f.pendingWithdrawals(alice), PRICE);
    }

    function test_Release_OneSecondLate_5PercentPenalty() public {
        uint256 jobId = _inProgress();
        vm.warp(f.getJob(0, jobId).deadlineTimestamp + 1);
        _submit(alice, jobId);
        _release(jobId);

        assertEq(f.pendingWithdrawals(alice), 0.95 ether);
        assertEq(f.pendingWithdrawals(bob), 0.05 ether);
    }

    function test_Release_ExactlyOneDayLate_StillOneDay() public {
        uint256 jobId = _inProgress();
        vm.warp(f.getJob(0, jobId).deadlineTimestamp + 1 days);
        _submit(alice, jobId);
        _release(jobId);
        assertEq(f.pendingWithdrawals(alice), 0.95 ether);
    }

    function test_Release_OneDayAndOneSecondLate_TwoDays() public {
        uint256 jobId = _inProgress();
        vm.warp(f.getJob(0, jobId).deadlineTimestamp + 1 days + 1);
        _submit(alice, jobId);
        _release(jobId);

        assertEq(f.pendingWithdrawals(alice), 0.9 ether);
        assertEq(f.pendingWithdrawals(bob), 0.1 ether);
    }

    function test_Release_PenaltyCapsAt100Percent() public {
        uint256 jobId = _inProgress();
        vm.warp(f.getJob(0, jobId).deadlineTimestamp + 100 days);
        _submit(alice, jobId);
        _release(jobId);

        assertEq(f.pendingWithdrawals(alice), 0);
        assertEq(f.pendingWithdrawals(bob), PRICE);
    }

    function test_Release_EmployerCannotGamePenaltyByWaiting() public {
        uint256 jobId = _submittedOnTime();
        // employer sits on the work for days past the deadline
        vm.warp(block.timestamp + 6 days);
        _release(jobId);
        // penalty is measured from submission, so the freelancer is paid in full
        assertEq(f.pendingWithdrawals(alice), PRICE);
        assertEq(f.pendingWithdrawals(bob), 0);
    }

    function test_Release_BeforeSubmitReverts() public {
        uint256 jobId = _inProgress();
        vm.prank(bob);
        vm.expectRevert(_notInStatus(jobId, Freelancer.Status.InProgress));
        f.releaseEscrowPayment(0, jobId);
    }

    function test_Release_TwiceReverts() public {
        uint256 jobId = _submittedOnTime();
        _release(jobId);
        vm.prank(bob);
        vm.expectRevert(_notInStatus(jobId, Freelancer.Status.Paid));
        f.releaseEscrowPayment(0, jobId);
    }

    function test_Release_NonEmployerReverts() public {
        uint256 jobId = _submittedOnTime();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Freelancer.Freelancer_UnauthorizedEmployer.selector, 0, alice));
        f.releaseEscrowPayment(0, jobId);
    }

    function test_Release_FreelancerCanBeHiredAgain() public {
        uint256 job1 = _submittedOnTime();
        _release(job1);

        uint256 job2 = _create();
        _apply(0, alice, job2);
        _hire(0, job2);
        assertTrue(_status(job2) == Freelancer.Status.InProgress);
    }

    // ------------------------------------------------------------------
    // Withdraw
    // ------------------------------------------------------------------
    function test_Withdraw_NothingReverts() public {
        vm.prank(stranger);
        vm.expectRevert(Freelancer.Freelancer_NothingToWithdraw.selector);
        f.withdraw();
    }

    function test_Withdraw_CannotWithdrawTwice() public {
        uint256 jobId = _submittedOnTime();
        _release(jobId);

        vm.startPrank(alice);
        f.withdraw();
        vm.expectRevert(Freelancer.Freelancer_NothingToWithdraw.selector);
        f.withdraw();
        vm.stopPrank();
    }

    function test_Withdraw_EmployerCannotDrainEscrowOfHiredJob() public {
        _inProgress();
        // bob has no pending balance, funds are locked in the job
        vm.prank(bob);
        vm.expectRevert(Freelancer.Freelancer_NothingToWithdraw.selector);
        f.withdraw();
        assertEq(address(f).balance, PRICE);
    }

    function test_Withdraw_ReentrancyAttemptDoesNotDoubleSpend() public {
        MaliciousFreelancer mal = new MaliciousFreelancer(f);
        mal.register();
        uint256 malId = f.freelancerIdByAddress(address(mal));

        // second job so the contract also holds unrelated funds the attacker must not reach
        _create();
        uint256 jobId = _create();

        mal.applyFor(malId, 0, jobId);
        _hire(malId, jobId);
        mal.submit(0, jobId);
        _release(jobId);

        mal.doWithdraw();

        assertEq(address(mal).balance, PRICE);
        assertEq(mal.reentryAttempts(), 1);
        assertFalse(mal.reenterSucceeded());
        assertEq(address(f).balance, PRICE); // the other job's escrow is untouched
    }

    function test_Withdraw_RejectingReceiverRevertsAndKeepsBalance() public {
        MaliciousFreelancer mal = new MaliciousFreelancer(f);
        mal.register();
        uint256 malId = f.freelancerIdByAddress(address(mal));

        uint256 jobId = _create();
        mal.applyFor(malId, 0, jobId);
        _hire(malId, jobId);
        mal.submit(0, jobId);
        _release(jobId);

        mal.setReject(true);
        vm.expectRevert(abi.encodeWithSelector(Freelancer.Freelancer_TransferFailed.selector, address(mal), PRICE));
        mal.doWithdraw();

        // balance preserved, and the employer's release was never blocked
        assertEq(f.pendingWithdrawals(address(mal)), PRICE);

        mal.setReject(false);
        mal.doWithdraw();
        assertEq(address(mal).balance, PRICE);
    }

    // ------------------------------------------------------------------
    // claimAfterTimeout
    // ------------------------------------------------------------------
    function test_ClaimAfterTimeout_TooEarlyReverts() public {
        uint256 jobId = _submittedOnTime();
        uint256 availableAt = f.getJob(0, jobId).submittedAt + f.REVIEW_TIMEOUT();

        vm.warp(availableAt - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Freelancer.Freelancer_TooEarly.selector, availableAt));
        f.claimAfterTimeout(0, jobId);
    }

    function test_ClaimAfterTimeout_PaysFreelancer() public {
        uint256 jobId = _submittedOnTime();
        vm.warp(block.timestamp + f.REVIEW_TIMEOUT());

        vm.prank(alice);
        f.claimAfterTimeout(0, jobId);

        assertTrue(_status(jobId) == Freelancer.Status.Paid);
        // submitted on time, so no penalty even though claim is long after the deadline
        assertEq(f.pendingWithdrawals(alice), PRICE);
        assertTrue(f.getFreelancerProfile(0).isAvailableHire);
    }

    function test_ClaimAfterTimeout_StillAppliesLatePenaltyFromSubmission() public {
        uint256 jobId = _inProgress();
        vm.warp(f.getJob(0, jobId).deadlineTimestamp + 1);
        _submit(alice, jobId);
        vm.warp(block.timestamp + f.REVIEW_TIMEOUT());

        vm.prank(alice);
        f.claimAfterTimeout(0, jobId);

        assertEq(f.pendingWithdrawals(alice), 0.95 ether);
        assertEq(f.pendingWithdrawals(bob), 0.05 ether);
    }

    function test_ClaimAfterTimeout_OnlyHiredFreelancer() public {
        uint256 jobId = _submittedOnTime();
        vm.warp(block.timestamp + f.REVIEW_TIMEOUT());

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Freelancer.Freelancer_UnauthorizedFreelancer.selector, 0, bob));
        f.claimAfterTimeout(0, jobId);
    }

    function test_ClaimAfterTimeout_NotSubmittedReverts() public {
        uint256 jobId = _inProgress();
        vm.prank(alice);
        vm.expectRevert(_notInStatus(jobId, Freelancer.Status.InProgress));
        f.claimAfterTimeout(0, jobId);
    }

    // ------------------------------------------------------------------
    // cancelStalledJob
    // ------------------------------------------------------------------
    function test_CancelStalled_TooEarlyReverts() public {
        uint256 jobId = _inProgress();
        uint256 availableAt = f.getJob(0, jobId).deadlineTimestamp + f.ABANDON_GRACE();

        vm.warp(availableAt - 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Freelancer.Freelancer_TooEarly.selector, availableAt));
        f.cancelStalledJob(0, jobId);
    }

    function test_CancelStalled_RefundsAndFreesFreelancer() public {
        uint256 jobId = _inProgress();
        vm.warp(f.getJob(0, jobId).deadlineTimestamp + f.ABANDON_GRACE());

        vm.prank(bob);
        f.cancelStalledJob(0, jobId);

        assertTrue(_status(jobId) == Freelancer.Status.Cancelled);
        assertEq(f.pendingWithdrawals(bob), PRICE);
        assertTrue(f.getFreelancerProfile(0).isAvailableHire);
    }

    function test_CancelStalled_AfterSubmissionReverts() public {
        uint256 jobId = _submittedOnTime();
        vm.warp(block.timestamp + 365 days);
        vm.prank(bob);
        vm.expectRevert(_notInStatus(jobId, Freelancer.Status.Submitted));
        f.cancelStalledJob(0, jobId);
    }

    function test_CancelStalled_NonEmployerReverts() public {
        uint256 jobId = _inProgress();
        vm.warp(block.timestamp + 365 days);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Freelancer.Freelancer_UnauthorizedEmployer.selector, 0, alice));
        f.cancelStalledJob(0, jobId);
    }

    // ------------------------------------------------------------------
    // Disputes
    // ------------------------------------------------------------------
    function test_Dispute_EmployerCanRaiseWhileSubmitted() public {
        uint256 jobId = _submittedOnTime();
        vm.prank(bob);
        f.raiseDispute(0, jobId);
        assertTrue(_status(jobId) == Freelancer.Status.Disputed);
    }

    function test_Dispute_FreelancerCanRaiseWhileInProgress() public {
        uint256 jobId = _inProgress();
        vm.prank(alice);
        f.raiseDispute(0, jobId);
        assertTrue(_status(jobId) == Freelancer.Status.Disputed);
    }

    function test_Dispute_StrangerReverts() public {
        uint256 jobId = _inProgress();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Freelancer.Freelancer_UnauthorizedEmployer.selector, 0, stranger));
        f.raiseDispute(0, jobId);
    }

    function test_Dispute_OtherFreelancerReverts() public {
        uint256 jobId = _inProgress();
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(Freelancer.Freelancer_UnauthorizedEmployer.selector, 0, carol));
        f.raiseDispute(0, jobId);
    }

    function test_Dispute_OpenJobReverts() public {
        uint256 jobId = _create();
        vm.prank(bob);
        vm.expectRevert(_notInStatus(jobId, Freelancer.Status.Open));
        f.raiseDispute(0, jobId);
    }

    function test_Dispute_BlocksReleaseAndTimeoutClaim() public {
        uint256 jobId = _submittedOnTime();
        vm.prank(bob);
        f.raiseDispute(0, jobId);

        vm.prank(bob);
        vm.expectRevert(_notInStatus(jobId, Freelancer.Status.Disputed));
        f.releaseEscrowPayment(0, jobId);

        vm.warp(block.timestamp + 30 days);
        vm.prank(alice);
        vm.expectRevert(_notInStatus(jobId, Freelancer.Status.Disputed));
        f.claimAfterTimeout(0, jobId);
    }

    function test_ResolveDispute_SplitsEscrow() public {
        uint256 jobId = _submittedOnTime();
        vm.prank(bob);
        f.raiseDispute(0, jobId);

        vm.prank(owner);
        f.resolveDispute(0, jobId, 7000);

        assertTrue(_status(jobId) == Freelancer.Status.Paid);
        assertEq(f.pendingWithdrawals(alice), 0.7 ether);
        assertEq(f.pendingWithdrawals(bob), 0.3 ether);
        assertTrue(f.getFreelancerProfile(0).isAvailableHire);
    }

    function test_ResolveDispute_FullRefundToEmployer() public {
        uint256 jobId = _inProgress();
        vm.prank(bob);
        f.raiseDispute(0, jobId);
        vm.prank(owner);
        f.resolveDispute(0, jobId, 0);

        assertEq(f.pendingWithdrawals(alice), 0);
        assertEq(f.pendingWithdrawals(bob), PRICE);
    }

    function test_ResolveDispute_FullToFreelancer() public {
        uint256 jobId = _inProgress();
        vm.prank(alice);
        f.raiseDispute(0, jobId);
        vm.prank(owner);
        f.resolveDispute(0, jobId, 10_000);

        assertEq(f.pendingWithdrawals(alice), PRICE);
        assertEq(f.pendingWithdrawals(bob), 0);
    }

    function test_ResolveDispute_OnlyOwner() public {
        uint256 jobId = _inProgress();
        vm.prank(bob);
        f.raiseDispute(0, jobId);

        vm.prank(bob);
        vm.expectRevert(Freelancer.Freelancer_NotAuthorisedOwner.selector);
        f.resolveDispute(0, jobId, 10_000);
    }

    function test_ResolveDispute_ShareOver100PercentReverts() public {
        uint256 jobId = _inProgress();
        vm.prank(bob);
        f.raiseDispute(0, jobId);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Freelancer.Freelancer_InvalidShare.selector, 10_001));
        f.resolveDispute(0, jobId, 10_001);
    }

    function test_ResolveDispute_NotDisputedReverts() public {
        uint256 jobId = _inProgress();
        vm.prank(owner);
        vm.expectRevert(_notInStatus(jobId, Freelancer.Status.InProgress));
        f.resolveDispute(0, jobId, 5000);
    }

    function test_ResolveDispute_TwiceReverts() public {
        uint256 jobId = _inProgress();
        vm.prank(bob);
        f.raiseDispute(0, jobId);
        vm.startPrank(owner);
        f.resolveDispute(0, jobId, 5000);
        vm.expectRevert(_notInStatus(jobId, Freelancer.Status.Paid));
        f.resolveDispute(0, jobId, 5000);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Platform fee
    // ------------------------------------------------------------------
    function test_Fee_SetAndCap() public {
        vm.prank(owner);
        f.setPlatformFee(500);
        assertEq(f.platformFeeBps(), 500);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Freelancer.Freelancer_FeeTooHigh.selector, 1001));
        f.setPlatformFee(1001);
    }

    function test_Fee_OnlyOwnerCanSet() public {
        vm.prank(stranger);
        vm.expectRevert(Freelancer.Freelancer_NotAuthorisedOwner.selector);
        f.setPlatformFee(100);
    }

    function test_Fee_TakenFromFreelancerPayout() public {
        vm.prank(owner);
        f.setPlatformFee(500); // 5%

        uint256 jobId = _submittedOnTime();
        _release(jobId);

        assertEq(f.pendingWithdrawals(alice), 0.95 ether);
        assertEq(f.pendingWithdrawals(bob), 0);
        assertEq(f.platformFees(), 0.05 ether);
    }

    function test_Fee_AppliesAfterLatePenalty() public {
        vm.prank(owner);
        f.setPlatformFee(500);

        uint256 jobId = _inProgress();
        vm.warp(f.getJob(0, jobId).deadlineTimestamp + 1);
        _submit(alice, jobId);
        _release(jobId);

        // gross 0.95, fee 5% of 0.95 = 0.0475, freelancer 0.9025, employer refund 0.05
        assertEq(f.pendingWithdrawals(alice), 0.9025 ether);
        assertEq(f.pendingWithdrawals(bob), 0.05 ether);
        assertEq(f.platformFees(), 0.0475 ether);
    }

    function test_Fee_OwnerWithdraws() public {
        vm.prank(owner);
        f.setPlatformFee(1000);
        uint256 jobId = _submittedOnTime();
        _release(jobId);

        address treasury = makeAddr("treasury");
        vm.prank(owner);
        f.withdrawPlatformFees(treasury);

        assertEq(treasury.balance, 0.1 ether);
        assertEq(f.platformFees(), 0);
    }

    function test_Fee_WithdrawNothingReverts() public {
        vm.prank(owner);
        vm.expectRevert(Freelancer.Freelancer_NothingToWithdraw.selector);
        f.withdrawPlatformFees(owner);
    }

    function test_Fee_WithdrawToZeroAddressReverts() public {
        vm.prank(owner);
        vm.expectRevert(Freelancer.Freelancer_InvalidAddress.selector);
        f.withdrawPlatformFees(address(0));
    }

    function test_Fee_OnlyOwnerCanWithdraw() public {
        vm.prank(stranger);
        vm.expectRevert(Freelancer.Freelancer_NotAuthorisedOwner.selector);
        f.withdrawPlatformFees(stranger);
    }

    // ------------------------------------------------------------------
    // Views / pagination
    // ------------------------------------------------------------------
    function test_Pagination_Freelancers() public {
        for (uint256 i = 0; i < 60; i++) {
            vm.prank(address(uint160(0x1000 + i)));
            f.registerFreelancerProfile("X", 1, 1);
        }
        // 2 from setUp + 60
        assertEq(f.getNumberOfRegisteredFreeLancers(), 62);
        assertEq(f.getFreelancerProfiles(0, 10).length, 10);
        assertEq(f.getFreelancerProfiles(60, 10).length, 2);
        assertEq(f.getFreelancerProfiles(62, 10).length, 0);
        assertEq(f.getFreelancerProfiles(500, 10).length, 0);
        assertEq(f.getFreelancerProfiles(0, 1000).length, 50); // clamped to MAX_PAGE_SIZE
        assertEq(f.getFreelancerProfiles(5, 3)[0].id, 5);
    }

    function test_Pagination_Jobs() public {
        _create();
        _create();
        _create();

        assertEq(f.getNumberOfCreatedJobList(0), 3);
        assertEq(f.getJobList(0, 0, 2).length, 2);
        assertEq(f.getJobList(0, 2, 10).length, 1);
        assertEq(f.getJobList(0, 3, 10).length, 0);
        assertEq(f.getJobList(0, 1, 1)[0].id, 1);
    }

    function test_GetJob_InvalidIdReverts() public {
        vm.expectRevert(abi.encodeWithSelector(Freelancer.Freelancer_InvalidJobId.selector, 0, 5));
        f.getJob(0, 5);
    }

    function test_OpenJobCount_TracksMultipleJobs() public {
        uint256 j0 = _create();
        _create();
        assertEq(f.openJobCount(0), 2);

        _apply(0, alice, j0);
        _hire(0, j0);
        assertEq(f.openJobCount(0), 1);
        assertTrue(f.getEmployerProfile(0).isHiring);
    }

    function test_ContractRejectsPlainEther() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok, ) = address(f).call{value: 1 ether}("");
        assertFalse(ok);
    }

    // ------------------------------------------------------------------
    // Fuzz / invariant-style checks
    // ------------------------------------------------------------------
    /// Whatever the lateness and fee, funds are conserved and nothing is stuck.
    function testFuzz_Release_ConservesFunds(uint32 lateSeconds, uint256 feeBps) public {
        feeBps = bound(feeBps, 0, f.MAX_PLATFORM_FEE_BPS());
        vm.prank(owner);
        f.setPlatformFee(feeBps);

        uint256 jobId = _inProgress();
        vm.warp(f.getJob(0, jobId).deadlineTimestamp + lateSeconds);
        _submit(alice, jobId);
        _release(jobId);

        uint256 total = f.pendingWithdrawals(alice) + f.pendingWithdrawals(bob) + f.platformFees();
        assertEq(total, PRICE);
        assertEq(address(f).balance, PRICE);
    }

    /// The freelancer is never paid more than the price and never more when later.
    function testFuzz_LatePenalty_Monotonic(uint32 a, uint32 b) public {
        vm.assume(a <= b);

        uint256 jobA = _inProgress();
        vm.warp(f.getJob(0, jobA).deadlineTimestamp + a);
        _submit(alice, jobA);
        _release(jobA);
        uint256 payA = f.pendingWithdrawals(alice);

        uint256 jobB = _inProgress();
        vm.warp(f.getJob(0, jobB).deadlineTimestamp + b);
        _submit(alice, jobB);
        _release(jobB);
        uint256 payB = f.pendingWithdrawals(alice) - payA;

        assertLe(payA, PRICE);
        assertLe(payB, payA);
    }

    function testFuzz_ResolveDispute_ConservesFunds(uint256 shareBps, uint256 feeBps) public {
        shareBps = bound(shareBps, 0, f.BPS_DENOMINATOR());
        feeBps = bound(feeBps, 0, f.MAX_PLATFORM_FEE_BPS());
        vm.prank(owner);
        f.setPlatformFee(feeBps);

        uint256 jobId = _inProgress();
        vm.prank(bob);
        f.raiseDispute(0, jobId);
        vm.prank(owner);
        f.resolveDispute(0, jobId, shareBps);

        uint256 total = f.pendingWithdrawals(alice) + f.pendingWithdrawals(bob) + f.platformFees();
        assertEq(total, PRICE);
    }

    function testFuzz_CreateJob_RequiresExactValue(uint256 price, uint256 sent) public {
        price = bound(price, 1, 50 ether);
        sent = bound(sent, 0, 50 ether);
        vm.assume(price != sent);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Freelancer.Freelancer_IncorrectjobCreationFee.selector, price, sent));
        f.createjobListing{value: sent}(0, Freelancer.CreateJobListingInput("T", "d", DURATION, price));
    }
}
