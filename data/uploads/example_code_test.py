"""Example module for testing Mycel Code extraction.

Upload this single file in Code mode. You should see:
  • structure : module / class / function / parameter nodes; DEFINES, CONTAINS
  • Stage 2   : INHERITS, CALLS, INSTANTIATES, HAS_TYPE, RETURNS, READS, WRITES
Each Stage-2 edge carries its line number + the exact source line as evidence.
"""

DEFAULT_RATE = 0.05      # module constant  -> READS/WRITES target
_log = []                # module variable

class Account:
    def __init__(self, balance: float):
        self.balance = balance
    def deposit(self, amount: float):
        self.balance = self.balance + amount
        self._record("deposit")            # self-call -> CALLS Account._record
    def _record(self, kind: str):
        _log.append(kind)                  # READS _log (the name is loaded to call .append)
    def interest(self) -> float:           # RETURNS float (builtin, skipped)
        return self.balance * DEFAULT_RATE # READS DEFAULT_RATE

class Savings(Account):                    # INHERITS Account
    def interest(self) -> float:
        return self.interest_base() * 2    # self-call -> CALLS Savings.interest_base
    def interest_base(self) -> float:
        return self.balance * DEFAULT_RATE # READS DEFAULT_RATE

def open_account(start: float) -> Account: # RETURNS Account (user type)
    acct = Account(start)                  # INSTANTIATES Account
    return acct

def audit(acct: Account):                  # HAS_TYPE: param acct -> Account
    return open_account(acct.balance)      # CALLS open_account
