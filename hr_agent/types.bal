type LeaveType "annual"|"sick"|"casual";

type Employee record {|
    string id;
    string name;
    string email;
    string department;
    string title;
    string managerId?;
|};

type LeaveBalance record {|
    int annual;
    int sick;
    int casual;
|};

type LeaveRequest record {|
    string requestId;
    string employeeId;
    LeaveType leaveType;
    string startDate;
    string endDate;
    int days;
    string reason;
    string status;
|};

type Holiday record {|
    string date;
    string name;
|};

type Policy record {|
    string title;
    string[] keywords;
    string summary;
|};

# Body of a `POST /invocations` request.
type InvocationRequest record {
    # The user's message to the HR assistant
    string message;
    # Optional ID of the employee asking, so the agent doesn't need to ask for it
    string employeeId?;
    # Optional conversation ID; falls back to the Foundry session ID
    string sessionId?;
};

type InvocationResponse record {|
    string response;
    string sessionId;
|};
