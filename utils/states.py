from aiogram.fsm.state import State, StatesGroup


class WalletSt(StatesGroup):
    amount = State()
    receipt = State()


class PurchaseSt(StatesGroup):
    server = State()
    gb = State()
    service_name = State()
    confirm = State()
    receipt = State()


class RenewSt(StatesGroup):
    gb = State()
    confirm = State()
    receipt = State()


class ServiceSt(StatesGroup):
    confirm_change = State()
