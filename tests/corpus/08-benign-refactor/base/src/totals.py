def line_total(items):
    total = 0
    for item in items:
        total = total + item["price"] * item["qty"]
    return total
