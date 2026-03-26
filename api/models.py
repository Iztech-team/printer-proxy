from typing import List, Optional
from pydantic import BaseModel


class ReceiptItem(BaseModel):
    name: str
    qty: int = 1
    price: float = 0.0


class PrintRequest(BaseModel):
    type: str
    cut: bool = True
    lines_after: int = 0

    text: Optional[str] = None
    bold: bool = False
    underline: int = 0
    width: int = 1
    height: int = 1
    align: str = "left"
    invert: bool = False

    header: str = "BARAKA"
    subheader: Optional[str] = None
    items: List[ReceiptItem] = []
    subtotal: Optional[float] = None
    tax: Optional[float] = None
    discount: Optional[float] = None
    total: Optional[float] = None
    footer: Optional[str] = None

    size: int = 3
    center: bool = True

    code: Optional[str] = None
    barcode_type: str = "CODE39"

    base64: Optional[str] = None
    hex: Optional[str] = None
