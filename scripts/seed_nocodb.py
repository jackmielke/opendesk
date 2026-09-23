#!/usr/bin/env python3
"""Seed a local NocoDB with a catering CRM base (inspired by Radish Hub).

Usage: NOCO_URL=http://localhost:8080 NOCO_TOKEN=xxx python3 scripts/seed_nocodb.py
All data is fictional.
"""
import json, os, random, urllib.request, datetime

URL = os.environ.get("NOCO_URL", "http://localhost:8080")
TOKEN = os.environ["NOCO_TOKEN"]
random.seed(7)


def api(method, path, body=None):
    req = urllib.request.Request(
        URL + path,
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"xc-token": TOKEN, "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req) as r:
        raw = r.read()
        return json.loads(raw) if raw else None


def sel(options, colors=None):
    palette = ["#cfdffe", "#d0f1fd", "#c2f5e9", "#ffdaf6", "#ffdce5", "#fee2d5", "#ffeab6", "#d1f7c4", "#ede2fe", "#eeeeee"]
    return {"options": [{"title": o, "color": (colors or palette)[i % len(palette)]} for i, o in enumerate(options)]}


def col(title, uidt, **kw):
    c = {"column_name": title.lower().replace(" ", "_"), "title": title, "uidt": uidt}
    c.update(kw)
    return c


STAGES = ["Inquiry", "Proposal Sent", "Tasting", "Booked", "Completed", "Lost"]
STYLES = ["Buffet", "Family Style", "Plated", "Drop-off", "Stations"]
CLIENT_TYPES = ["Corporate", "Wedding", "Private", "Nonprofit"]


def main():
    base = api("POST", "/api/v2/meta/bases", {"title": "Catering CRM"})
    bid = base["id"]
    print("base", bid)

    clients_t = api("POST", f"/api/v2/meta/bases/{bid}/tables", {
        "table_name": "clients", "title": "Clients",
        "columns": [
            col("Name", "SingleLineText", pv=True),
            col("Company", "SingleLineText"),
            col("Email", "Email"),
            col("Phone", "PhoneNumber"),
            col("Type", "SingleSelect", colOptions=sel(CLIENT_TYPES)),
            col("Lifetime Value", "Currency"),
            col("Notes", "LongText"),
        ],
    })
    events_t = api("POST", f"/api/v2/meta/bases/{bid}/tables", {
        "table_name": "events", "title": "Events",
        "columns": [
            col("Event", "SingleLineText", pv=True),
            col("Client", "SingleLineText"),
            col("Date", "Date"),
            col("Guests", "Number"),
            col("Stage", "SingleSelect", colOptions=sel(STAGES, ["#cfdffe", "#ffeab6", "#ede2fe", "#d1f7c4", "#c2f5e9", "#ffdce5"])),
            col("Budget", "Currency"),
            col("Venue", "SingleLineText"),
            col("Service Style", "SingleSelect", colOptions=sel(STYLES)),
            col("Lead Captain", "SingleLineText"),
            col("Notes", "LongText"),
        ],
    })
    staff_t = api("POST", f"/api/v2/meta/bases/{bid}/tables", {
        "table_name": "staff", "title": "Staff",
        "columns": [
            col("Name", "SingleLineText", pv=True),
            col("Role", "SingleSelect", colOptions=sel(["Captain", "Server", "Chef", "Bartender", "Driver"])),
            col("Phone", "PhoneNumber"),
            col("Available", "Checkbox"),
            col("Rating", "Rating"),
        ],
    })
    menu_t = api("POST", f"/api/v2/meta/bases/{bid}/tables", {
        "table_name": "menu_items", "title": "Menu",
        "columns": [
            col("Item", "SingleLineText", pv=True),
            col("Category", "SingleSelect", colOptions=sel(["Passed App", "Salad", "Entree", "Side", "Dessert", "Beverage"])),
            col("Price Per Guest", "Currency"),
            col("Dietary", "MultiSelect", colOptions=sel(["V", "VG", "GF", "DF", "NF"])),
            col("Seasonal", "Checkbox"),
        ],
    })

    firsts = ["Maya", "Theo", "Priya", "Jonah", "Lena", "Marcus", "Ava", "Noah", "Sofia", "Eli", "Harper", "Ravi", "Chloe", "Owen", "Zara", "Felix", "Nora", "Sam"]
    lasts = ["Okafor", "Lindqvist", "Ramirez", "Chen", "Whitaker", "Nakamura", "Duarte", "Patel", "Brennan", "Kowalski", "Haddad", "Moreau"]
    companies = ["Northwind Robotics", "Cascade Health", "Pier 9 Ventures", "Evergreen Foundation", "Tidal Labs", "Summit Bank", "Juniper Schools", "Orca Analytics", "", "", "", ""]
    clients = []
    for i in range(24):
        f, l = random.choice(firsts), random.choice(lasts)
        co = random.choice(companies)
        t = "Corporate" if co else random.choice(["Wedding", "Private", "Wedding"])
        if co in ("Evergreen Foundation", "Juniper Schools"):
            t = "Nonprofit"
        clients.append({
            "Name": f"{f} {l}", "Company": co or None,
            "Email": f"{f.lower()}.{l.lower()}@example.com",
            "Phone": f"(206) 555-{random.randint(1000, 9999)}",
            "Type": t, "Lifetime Value": random.choice([0, 1800, 4200, 7600, 12500, 23800, 41000]),
            "Notes": random.choice(["Prefers text over email.", "Repeat client, loves the short rib.", "Referred by Pier 9.", "Needs COI for venue.", "", "Nut allergy in family."]),
        })
    api("POST", f"/api/v2/tables/{clients_t['id']}/records", clients)

    kinds = ["All-Hands Lunch", "Wedding Reception", "Board Dinner", "Holiday Party", "Rehearsal Dinner", "Product Launch", "Gala", "Birthday Dinner", "Offsite Breakfast", "Donor Brunch"]
    venues = ["Fremont Studios", "Olympic Sculpture Park", "Client Office", "Private Residence", "Within Sodo", "Canal Street Loft", "Bell Harbor", "Herban Farm"]
    captains = ["Terry", "Chris", "Dana", "Luis", "Mei"]
    today = datetime.date(2026, 9, 23)
    events = []
    for i in range(38):
        c = random.choice(clients)
        d = today + datetime.timedelta(days=random.randint(-60, 120))
        if d < today:
            stage = random.choice(["Completed", "Completed", "Lost"])
        else:
            stage = random.choice(["Inquiry", "Inquiry", "Proposal Sent", "Proposal Sent", "Tasting", "Booked", "Booked"])
        guests = random.choice([25, 40, 60, 85, 120, 150, 220, 300])
        events.append({
            "Event": f"{(c['Company'] or c['Name'].split()[1])} {random.choice(kinds)}",
            "Client": c["Name"], "Date": d.isoformat(), "Guests": guests, "Stage": stage,
            "Budget": guests * random.choice([38, 55, 72, 95, 120]),
            "Venue": random.choice(venues), "Service Style": random.choice(STYLES),
            "Lead Captain": random.choice(captains) if stage in ("Booked", "Completed") else None,
            "Notes": random.choice(["Gluten-free for 6.", "Load-in at 3pm, freight elevator.", "Wants passed apps + stations.", "Tasting booked with the couple.", "Follow up Friday.", ""]),
        })
    api("POST", f"/api/v2/tables/{events_t['id']}/records", events)

    staff = [{"Name": n, "Role": r, "Phone": f"(206) 555-{random.randint(1000, 9999)}", "Available": random.random() > .3, "Rating": random.randint(3, 5)}
             for n, r in [("Terry", "Captain"), ("Chris", "Chef"), ("Dana", "Captain"), ("Luis", "Captain"), ("Mei", "Captain"), ("Jordan", "Server"), ("Ali", "Server"), ("Bea", "Bartender"), ("Cam", "Server"), ("Dev", "Driver"), ("Esme", "Chef"), ("Finn", "Server"), ("Gia", "Bartender"), ("Hugo", "Server")]]
    api("POST", f"/api/v2/tables/{staff_t['id']}/records", staff)

    menu = [
        ("Smoked Trout Crostini", "Passed App", 6, "DF", True), ("Wild Mushroom Tart", "Passed App", 5, "V", True),
        ("Little Gem Caesar", "Salad", 8, "GF", False), ("Roasted Beet & Citrus", "Salad", 9, "VG,GF,DF", True),
        ("Braised Short Rib", "Entree", 34, "GF,DF", False), ("Cedar Plank Salmon", "Entree", 36, "GF,DF", True),
        ("Harissa Cauliflower Steak", "Entree", 24, "VG,GF,DF,NF", False), ("Herb Chicken Roulade", "Entree", 28, "GF", False),
        ("Crispy Fingerlings", "Side", 7, "VG,GF,DF", False), ("Charred Broccolini", "Side", 7, "VG,GF,DF", True),
        ("Olive Oil Cake", "Dessert", 9, "V,DF", False), ("Marionberry Crumble", "Dessert", 10, "V", True),
        ("Lavender Lemonade", "Beverage", 4, "VG,GF,DF,NF", True), ("Cold Brew Bar", "Beverage", 6, "VG,GF", False),
    ]
    api("POST", f"/api/v2/tables/{menu_t['id']}/records",
        [{"Item": a, "Category": b, "Price Per Guest": c, "Dietary": d, "Seasonal": e} for a, b, c, d, e in menu])

    print(json.dumps({"base": bid, "tables": {t["title"]: t["id"] for t in (clients_t, events_t, staff_t, menu_t)}}))


if __name__ == "__main__":
    main()
