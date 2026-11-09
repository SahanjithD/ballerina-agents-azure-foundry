import ballerina/ai;
import ballerina/time;
import ballerina/uuid;

# Gets an employee's profile: name, email, department, job title and manager.
#
# + employeeId - The employee ID, e.g. E1001
# + return - The employee profile, or an error if the employee is not found
@ai:AgentTool
isolated function getEmployeeProfile(string employeeId) returns Employee|error {
    Employee? employee = employees[employeeId];
    if employee is () {
        return error(string `No employee found with ID ${employeeId}`);
    }
    return employee;
}

# Gets an employee's remaining leave balance in days for each leave type.
#
# + employeeId - The employee ID, e.g. E1001
# + return - The remaining annual, sick and casual leave days
@ai:AgentTool
isolated function getLeaveBalance(string employeeId) returns LeaveBalance|error {
    lock {
        LeaveBalance? balance = leaveBalances[employeeId];
        if balance is () {
            return error(string `No leave balance found for employee ${employeeId}`);
        }
        return balance.clone();
    }
}

# Submits a leave request and deducts the days from the employee's balance.
# Only call this after the employee has confirmed the leave type and dates.
#
# + employeeId - The employee ID, e.g. E1001
# + leaveType - One of: annual, sick, casual
# + startDate - First day of leave in YYYY-MM-DD format
# + endDate - Last day of leave in YYYY-MM-DD format
# + reason - Short reason for the leave
# + return - The created leave request, or an error if the dates or balance are invalid
@ai:AgentTool
isolated function applyForLeave(string employeeId, LeaveType leaveType, string startDate, string endDate,
        string reason) returns LeaveRequest|error {
    int days = check countDays(startDate, endDate);
    lock {
        LeaveBalance? balance = leaveBalances[employeeId];
        if balance is () {
            return error(string `No leave balance found for employee ${employeeId}`);
        }
        int available = balance.get(leaveType);
        if days > available {
            return error(string `Requested ${days} ${leaveType} leave days but only ${available} remain`);
        }
        balance[leaveType] = available - days;
    }

    LeaveRequest request = {
        requestId: uuid:createType4AsString().substring(0, 8),
        employeeId,
        leaveType,
        startDate,
        endDate,
        days,
        reason,
        status: "PENDING_APPROVAL"
    };
    lock {
        leaveRequests.push(request.clone());
    }
    return request;
}

# Lists all leave requests an employee has submitted.
#
# + employeeId - The employee ID, e.g. E1001
# + return - The employee's leave requests
@ai:AgentTool
isolated function listLeaveRequests(string employeeId) returns LeaveRequest[] {
    lock {
        LeaveRequest[] matches = [];
        foreach LeaveRequest request in leaveRequests {
            if request.employeeId == employeeId {
                matches.push(request);
            }
        }
        return matches.clone();
    }
}

# Lists the company's public holidays.
#
# + return - The public holidays with their dates
@ai:AgentTool
isolated function getCompanyHolidays() returns Holiday[] => holidays;

# Searches HR policies (leave, remote work, expenses, code of conduct) by topic.
#
# + topic - A keyword or short phrase, e.g. "remote work" or "expenses"
# + return - The matching policies; all policies if nothing matches
@ai:AgentTool
isolated function searchHrPolicies(string topic) returns Policy[] {
    final string query = topic.toLowerAscii();
    Policy[] matches = from Policy policy in policies
        where policy.title.toLowerAscii().includes(query)
            || policy.keywords.some(isolated function(string keyword) returns boolean => query.includes(keyword) || keyword.includes(query))
        select policy;
    return matches.length() > 0 ? matches : policies;
}

// Counts calendar days between two YYYY-MM-DD dates, inclusive.
isolated function countDays(string startDate, string endDate) returns int|error {
    time:Utc 'start = check toUtc(startDate);
    time:Utc end = check toUtc(endDate);
    decimal seconds = time:utcDiffSeconds(end, 'start);
    if seconds < 0d {
        return error("End date must be on or after the start date");
    }
    return <int>(seconds / 86400d) + 1;
}

isolated function toUtc(string date) returns time:Utc|error {
    time:Utc|error utc = time:utcFromString(date + "T00:00:00Z");
    if utc is error {
        return error(string `Invalid date '${date}', expected YYYY-MM-DD`);
    }
    return utc;
}
