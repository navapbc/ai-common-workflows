def line_total(items):
    """Sum price x quantity across line items."""
    return sum(item["price"] * item["qty"] for item in items)
