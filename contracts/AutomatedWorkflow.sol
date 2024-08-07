// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IDep {
    function registerTask(
        address contractAddress,
        bytes calldata execData
    ) external returns (bytes32 taskId);
    function cancelTask(bytes32 taskId) external;
}

contract AutomatedWorkflow {
    using SafeERC20 for IERC20;

    // Define state variables
    IDep private _dep;
    address private _owner;

    mapping(address => mapping(uint256 => bool)) public activeWorkflows;
    mapping(uint256 => bool) public workflowActiveStatus;
    mapping(uint256 => uint256) public workflowTimestamps;
    mapping(uint256 => uint256) public workflowMaxGasLimits;
    mapping(uint256 => uint256) public workflowPrefunds;
    mapping(address => mapping(uint256 => uint256)) public userPrefunds;
    mapping(uint256 => address) public workflowDestinations;
    mapping(uint256 => bytes) public workflowExecData;

    event WorkflowRegistered(address indexed user, uint256 indexed workflowId);
    event WorkflowActivated(address indexed user, uint256 indexed workflowId);
    event WorkflowExecuted(
        address indexed user,
        uint256 indexed workflowId,
        uint256 timestamp
    );
    event Prefunded(
        address indexed user,
        uint256 indexed workflowId,
        uint256 amount
    );
    event PrefundWithdrawn(
        address indexed user,
        uint256 indexed workflowId,
        uint256 amount
    );

    constructor(IDep dep) {
        _dep = dep;
        _owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == _owner, "Not the owner");
        _;
    }

    modifier onlyActiveWorkflow(uint256 workflowId) {
        require(workflowActiveStatus[workflowId], "Workflow is not active");
        _;
    }

    function register(
        uint256 workflowId,
        address destination,
        bytes calldata data
    ) external {
        address user = msg.sender;
        require(
            !activeWorkflows[user][workflowId],
            "Workflow already registered"
        );

        workflowDestinations[workflowId] = destination;
        workflowExecData[workflowId] = data;

        activeWorkflows[user][workflowId] = true;

        emit WorkflowRegistered(user, workflowId);
    }

    function activate(
        uint256 workflowId,
        uint256 maxGasLimit
    ) external onlyOwner {
        workflowTimestamps[workflowId] = block.timestamp;
        workflowMaxGasLimits[workflowId] = maxGasLimit;
        workflowActiveStatus[workflowId] = true;

        emit WorkflowActivated(msg.sender, workflowId);
    }

    function prefund(
        uint256 workflowId
    ) external payable onlyActiveWorkflow(workflowId) {
        require(
            activeWorkflows[msg.sender][workflowId],
            "Workflow is not registered by sender"
        );

        uint256 maxGasLimit = workflowMaxGasLimits[workflowId];
        uint256 requiredPrefund = maxGasLimit * tx.gasprice;

        require(msg.value >= requiredPrefund, "Insufficient prefund amount");

        userPrefunds[msg.sender][workflowId] += msg.value;
        workflowPrefunds[workflowId] += msg.value;

        emit Prefunded(msg.sender, workflowId, msg.value);
    }

    function run(uint256 workflowId) external onlyActiveWorkflow(workflowId) {
        require(
            block.timestamp >= workflowTimestamps[workflowId] + 1 days,
            "Too soon to run the workflow"
        );

        require(workflowPrefunds[workflowId] > 0, "Insufficient prefund");

        uint256 initialGas = gasleft();
        workflowTimestamps[workflowId] = block.timestamp;

        address destination = workflowDestinations[workflowId];
        bytes memory execData = workflowExecData[workflowId];

        (bool success, ) = destination.call(execData);
        require(success, "Execution failed");

        uint256 gasUsed = initialGas - gasleft();
        uint256 gasCost = gasUsed * tx.gasprice;

        require(
            gasCost <= workflowPrefunds[workflowId],
            "Gas cost exceeds prefund"
        );
        workflowPrefunds[workflowId] -= gasCost;
        payable(msg.sender).transfer(gasCost);

        emit WorkflowExecuted(msg.sender, workflowId, block.timestamp);
    }

    function cancelTask(uint256 workflowId) external onlyOwner {
        workflowActiveStatus[workflowId] = false;
    }

    function setDEPAddress(IDep dep) external onlyOwner {
        _dep = dep;
    }

    function withdrawPrefund(uint256 workflowId, uint256 amount) external {
        require(
            userPrefunds[msg.sender][workflowId] >= amount,
            "Insufficient prefund"
        );

        userPrefunds[msg.sender][workflowId] -= amount;
        workflowPrefunds[workflowId] -= amount;
        payable(msg.sender).transfer(amount);

        emit PrefundWithdrawn(msg.sender, workflowId, amount);
    }

    receive() external payable {}

    function withdraw(uint256 amount) external onlyOwner {
        require(address(this).balance >= amount, "Insufficient balance");
        payable(_owner).transfer(amount);
    }
}
