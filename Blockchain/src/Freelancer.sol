//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

contract Freelancer{
    uint256 constant public LATE_PENALTY_BPS_PER_DAY = 500;
    uint256 constant public BPS_DENOMINATOR = 10_000;
    uint256 connectFee;
    address public owner;

    struct FreelancerProfile {
        uint256 id;
        string name;
        address wallet;
        uint8 experienceYears;
        bool isAvailableHire;
        uint256 hourlyRateInWei;        
    }

    struct EmployerProfile {
        uint256 id;
        string name;
        bool isHiring;
        address wallet;
        JobListing[] jobListing;       
    }

    struct CreateJobListingInput{
        string title;
        string description;
        uint256 deadlineTimestamp;
        uint256 fixedPriceInWei;
    }

    struct JobListing{
        uint256 id;
        string title;
        string description;
        uint256 deadlineTimestamp;
        bool isOpen;
        uint256 fixedPriceinWei;
        uint256 hiredFreelancerId;
        bool hasHiredFreelancer;
        bool isPaid;
    }


    FreelancerProfile[] freelancerProfiles;
    EmployerProfile[] employerProfiles;


    mapping(uint256=>address) public freelancerIdToAddress;
    mapping(uint256=>address) public employerIdToAddress;
    mapping (uint256 => uint256) public employerBalance;

    event FreelancerProfileRegistered(uint256 freelancerId, address caller);
    event EmployerProfileRegistered(uint256 employerId, address caller);

    error Freelancer_IncorrectjobCreationFee(uint256 expectedFee, uint256 actualFee);
    error Freelancer_JobClosed(uint256 jobId);
    error Freelancer_UnauthorizedEmployer(uint256 employerId, address caller);
    error Freelancer_UnauthorizedFreelancer(uint256 freelancerid,address caller);
    error Freelancer_InvalidJobId(uint256 employerId, uint256 jobId);
    error Freelancer_NotEnoughbalance(uint256 employerid,uint256 employerBalance);
    error Freelancer_FreelanceidMismatch(uint256 expectedFreelancerid, uint256 actualFreelancer);
    error Freelancer_JobIsAlreadyPaid(uint256 jobId);
    error Freelancer_PaymentToFreelancerFailed(address freelancer, uint256 amountSnet);
    error Freelancer_NotAuthorisedOwner();


    constructor(address _initialOwner) {
        owner = _initialOwner;
    }

    modifier onlyAuthorizedOwner(address newOwner){

        if (owner != msg.sender){
            revert Freelancer_NotAuthorisedOwner();
        }
        _; 
    }


    modifier onlyAuthorizedEmployer(uint256 employerId){
        address  employer = employerIdToAddress[employerId]; 
        if (employer != msg.sender || employer==address(0)){
            revert Freelancer_UnauthorizedEmployer(employerId, msg.sender);
        }
        _; 
    }

    modifier validateNumberOfFreelancer(uint256 freelancerId){
        if (freelancerId >= getNumberOfRegisteredFreeLancers() || freelancerIdToAddress[freelancerId]==address(0)){
            revert Freelancer_UnauthorizedFreelancer(freelancerId,msg.sender);
        }
        _;
    }

    modifier validateJobId(uint256 jobId, uint256 employerId){
        if (jobId>=getNumberOfCreatedJobList(employerId)){
            revert Freelancer_InvalidJobId(employerId, jobId);
        }
        _;
    }

    function getNumberOfRegisteredFreeLancers() public view returns(uint256){ 
        return freelancerProfiles.length;
    }

    function registerFreelancerProfile(
        string calldata name,
        uint8 experienceYears,
        uint256 hourlyRateInWei
    ) external{ 
        uint256 freelancerId = getNumberOfRegisteredFreeLancers();//New Registration Id

        FreelancerProfile memory freelancerProfile = FreelancerProfile({
            id:freelancerId,
            name:name,
            wallet:msg.sender,
            experienceYears:experienceYears,
            isAvailableHire:true,
            hourlyRateInWei:hourlyRateInWei
        });

        freelancerProfiles.push(freelancerProfile);
        freelancerIdToAddress[freelancerId] = msg.sender;

        emit FreelancerProfileRegistered(freelancerId,msg.sender);
    }

    function getFreelancerProfile() public view returns(FreelancerProfile[] memory) {
        return freelancerProfiles;
    }


    function getNumberOfRegisteredEmployers() public view returns(uint256){ 
        return employerProfiles.length;
    }

    function registerEmployerProfile (string calldata name) external{  
        uint256 employerId = getNumberOfRegisteredEmployers();

        EmployerProfile memory employerProfile = EmployerProfile({
            id:employerId,
            name:name,
            isHiring:false,
            wallet:msg.sender,
            jobListing: new JobListing[](0)   
        });

        employerProfiles.push(employerProfile);//Adds New Employer
        employerIdToAddress[employerId] = msg.sender;

        emit EmployerProfileRegistered(employerId,msg.sender);
    }

    function getNumberOfCreatedJobList(uint256 employerId) public view returns(uint256){
        return employerProfiles[employerId].jobListing.length;
    }

    function _getEmployerProfile(uint256 employerId) internal view returns(EmployerProfile storage) {
        return employerProfiles[employerId];
    }

    function createjobListing(uint256 employerId, CreateJobListingInput calldata jobListingInput) external payable onlyAuthorizedEmployer(employerId){
        
        uint256 fixedPriceForJob = jobListingInput.fixedPriceInWei;
        if (msg.value != fixedPriceForJob){
            revert Freelancer_IncorrectjobCreationFee(fixedPriceForJob, msg.value);
        }

        EmployerProfile storage employerProfile = _getEmployerProfile(employerId);
        uint256 jobId = getNumberOfCreatedJobList(employerId);
        JobListing memory newJob = JobListing({
            id:jobId,
            title:jobListingInput.title,
            description: jobListingInput.description,
            deadlineTimestamp: block.timestamp + jobListingInput.deadlineTimestamp,
            isOpen:true,
            fixedPriceinWei:jobListingInput.fixedPriceInWei,
            hiredFreelancerId:0,
            hasHiredFreelancer:false,
            isPaid:false
        });

        employerBalance[employerId] += jobListingInput.fixedPriceInWei ;
        employerProfile.jobListing.push(newJob);
        
    }

    function _requireJobIsOpen (JobListing memory job)  internal pure {
        if (job.isOpen != true){
            revert Freelancer_JobClosed(job.id);
        }
    }

    function _getJob(uint256 employerId, uint256 jobId) internal view returns(JobListing storage){
        return employerProfiles[employerId].jobListing[jobId];
    }

    function getJobList(uint256 employerId) external view returns(JobListing[] memory){
        return employerProfiles[employerId].jobListing;
    }

    function hireFreelancer(uint256 employerId, uint256 freelancerId, uint256 jobId) public onlyAuthorizedEmployer(employerId) validateNumberOfFreelancer(freelancerId) validateJobId(jobId, employerId){

        JobListing storage job = _getJob(employerId,jobId);
        _requireJobIsOpen(job);
        job.hiredFreelancerId = freelancerId;
        job.hasHiredFreelancer = true;
        job.isOpen = false;
    }

    function _sendPaymentToFreelancer(address freelancer, uint256 amountToSend) internal{
        (bool success,) = freelancer.call{value:amountToSend}("");

        if(success==false){
            revert Freelancer_PaymentToFreelancerFailed(freelancer, amountToSend);
        }
    }

    function _calculatePayment(uint256 amountToSend, uint256 jobDeadlineTimestamp) internal view returns(uint256){
        if(block.timestamp<=jobDeadlineTimestamp){
            return amountToSend;
        }
        uint256 delayinCOmpletion = block.timestamp - jobDeadlineTimestamp;

        uint256 delayInDays = (delayinCOmpletion + 1 days -1)/1 days;

        uint256 deductionBps = delayInDays * LATE_PENALTY_BPS_PER_DAY ;

        if(deductionBps>BPS_DENOMINATOR){
            deductionBps = BPS_DENOMINATOR;
        }

        uint256 deductionAmount = (amountToSend*deductionBps)/BPS_DENOMINATOR;

        return amountToSend-deductionAmount;
    }

    function releaseEscrowPayment(uint256 employerId, uint256 jobId, uint256 freelancerId) public onlyAuthorizedEmployer(employerId) validateNumberOfFreelancer(freelancerId) validateJobId(jobId, employerId){
      JobListing storage job =_getJob(employerId,jobId);
      uint256 amountToSend =job.fixedPriceinWei;

      if(employerBalance[employerId]<amountToSend){
        revert Freelancer_NotEnoughbalance(employerId, employerBalance[employerId]);
      }

      if(freelancerId != job.hiredFreelancerId){
        revert Freelancer_FreelanceidMismatch(job.hiredFreelancerId, freelancerId);
      }

      if(job.isPaid == true){
        revert Freelancer_JobIsAlreadyPaid(job.id);
      }

      job.isPaid = true;
      employerBalance[employerId] -= amountToSend;
      uint256 paymentAmount = _calculatePayment(amountToSend, job.deadlineTimestamp);
      _sendPaymentToFreelancer(freelancerIdToAddress[freelancerId],paymentAmount);
    }

    function modifyOwner(address newOwner) external onlyAuthorizedOwner (newOwner) {
        owner = newOwner;
    }

    function withdrawAmount(uint256 employerId, uint256 withdrawlAmount) external onlyAuthorizedEmployer(employerId){
        if(employerBalance[employerId]<withdrawlAmount){
            revert  Freelancer_NotEnoughbalance(employerId,employerBalance[employerId]);
        }
        employerBalance[employerId] -= withdrawlAmount;
        (bool success,) = employerIdToAddress[employerId].call{value:withdrawlAmount}("");
        require(success==false,"Transfer failed to employer");
    }

}