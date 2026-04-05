# Personal CRM

## Description

A local-first personal CRM for tracking contacts, relationships, and follow-ups. Data is stored in `/sandbox/.openclaw-data/crm/` as JSON files. Use this skill when the user asks about contacts, follow-ups, or relationship management.

## Commands

- `/crm add` — Add a new contact
- `/crm search <query>` — Search contacts by name, company, or tags
- `/crm update <name>` — Update a contact's information or add notes
- `/crm followups` — Show contacts due for follow-up
- `/crm list` — List all contacts

## Data Format

Each contact is a JSON file in `/sandbox/.openclaw-data/crm/contacts/`:

```json
{
  "name": "Full Name",
  "company": "Company",
  "role": "Title",
  "email": "email@example.com",
  "phone": "+1...",
  "tags": ["investor", "friend", "advisor"],
  "notes": [
    {"date": "2026-04-01", "text": "Met at conference, interested in AI infra"}
  ],
  "lastContact": "2026-04-01",
  "followUpDate": "2026-04-15",
  "followUpNote": "Send deck"
}
```

## Instructions

### add

1. Ask for name (required), then company, role, email, tags
2. Create a JSON file named `{slugified-name}.json` in the contacts directory
3. Set `lastContact` to today
4. Ask if there's a follow-up needed

### search

1. Read all JSON files in the contacts directory
2. Match against name, company, role, tags, and notes
3. Return matching contacts with key details

### update

1. Find the contact by name (fuzzy match OK)
2. Ask what to update
3. If adding a note, prepend today's date
4. Update `lastContact` to today

### followups

1. Read all contacts
2. Filter to those with `followUpDate` on or before today
3. Sort by date (most overdue first)
4. Show name, follow-up note, and how overdue

### list

1. Read all contacts
2. Show a summary table: name, company, last contact date, tags
