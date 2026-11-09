// Mock HR data for the demo. Leave balances and requests live in memory, so they reset
// whenever the hosted-agent sandbox is recycled.

final readonly & map<Employee> employees = {
    "E1001": {id: "E1001", name: "Nimal Perera", email: "nimal@example.com", department: "Engineering", title: "Senior Software Engineer", managerId: "E1003"},
    "E1002": {id: "E1002", name: "Ayesha Fernando", email: "ayesha@example.com", department: "Marketing", title: "Marketing Specialist", managerId: "E1004"},
    "E1003": {id: "E1003", name: "Kasun Silva", email: "kasun@example.com", department: "Engineering", title: "Engineering Manager"},
    "E1004": {id: "E1004", name: "Priya Jayasinghe", email: "priya@example.com", department: "Marketing", title: "Head of Marketing"}
};

isolated map<LeaveBalance> leaveBalances = {
    "E1001": {annual: 14, sick: 7, casual: 7},
    "E1002": {annual: 10, sick: 7, casual: 5},
    "E1003": {annual: 18, sick: 7, casual: 7},
    "E1004": {annual: 20, sick: 7, casual: 7}
};

isolated LeaveRequest[] leaveRequests = [];

final readonly & Holiday[] holidays = [
    {date: "2026-01-01", name: "New Year's Day"},
    {date: "2026-04-13", name: "Sinhala and Tamil New Year's Eve"},
    {date: "2026-04-14", name: "Sinhala and Tamil New Year's Day"},
    {date: "2026-05-01", name: "Labour Day"},
    {date: "2026-12-25", name: "Christmas Day"},
    {date: "2027-01-01", name: "New Year's Day"}
];

final readonly & Policy[] policies = [
    {
        title: "Leave Policy",
        keywords: ["leave", "annual", "sick", "casual", "vacation", "time off"],
        summary: "Annual leave must be requested at least 3 days in advance. Sick leave over 2 consecutive " +
            "days needs a medical certificate. Up to 5 unused annual leave days carry over to the next year."
    },
    {
        title: "Remote Work Policy",
        keywords: ["remote", "work from home", "wfh", "hybrid"],
        summary: "Employees may work remotely up to 3 days a week with manager approval. Core hours are " +
            "10:00-15:00 local time."
    },
    {
        title: "Expense Reimbursement Policy",
        keywords: ["expense", "reimbursement", "travel", "claim"],
        summary: "Submit expense claims with receipts within 30 days. Claims over USD 500 need director approval."
    },
    {
        title: "Code of Conduct",
        keywords: ["conduct", "harassment", "ethics", "behaviour", "behavior"],
        summary: "Treat colleagues with respect. Report concerns to HR or through the anonymous ethics hotline."
    }
];
