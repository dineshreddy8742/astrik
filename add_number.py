#!/usr/bin/env python3
"""
Helper script to add/update Vobiz phone numbers in Dograh.

Usage:
  python add_number.py <number> <label> [--workflow <id>] [--default]

Examples:
  # Add a number for Pace Engineering College, linked to workflow 1
  python add_number.py +918065481144 "Pace Engineering College" --workflow 1

  # Add a number for ABC College, linked to workflow 2, make it the outbound default
  python add_number.py +918065481145 "ABC College" --workflow 2 --default

  # Just add a number (no workflow assigned yet)
  python add_number.py +918065481146 "XYZ College"

  # List all numbers
  python add_number.py --list
"""
import sys
import subprocess

def run_sql(sql: str, label: str = ""):
    if label:
        print(f"\n>> {label}")
    result = subprocess.run(
        ["docker", "exec", "dograh-postgres-1", "psql", "-U", "postgres", "-d", "postgres", "-c", sql.strip()],
        capture_output=True, text=True
    )
    if result.stdout:
        print(result.stdout)
    if result.returncode != 0 and result.stderr:
        print(f"ERROR: {result.stderr}")
        sys.exit(1)

def list_numbers():
    run_sql("""
        SELECT 
            p.id,
            p.address AS number,
            p.label,
            p.is_default_caller_id AS default_outbound,
            p.inbound_workflow_id AS workflow_id,
            w.name AS workflow_name
        FROM telephony_phone_numbers p
        LEFT JOIN workflows w ON w.id = p.inbound_workflow_id
        ORDER BY p.id;
    """, "All Numbers in Dograh")

def list_workflows():
    run_sql("""
        SELECT id, name FROM workflows ORDER BY id;
    """, "Available Workflows")

def add_number(number: str, label: str, workflow_id=None, make_default=False):
    if not number.startswith("+"):
        number = "+" + number

    if make_default:
        run_sql("""
            UPDATE telephony_phone_numbers 
            SET is_default_caller_id = false 
            WHERE telephony_configuration_id = 1 AND is_default_caller_id = true;
        """, "Unsetting current default caller ID")

    workflow_val = str(workflow_id) if workflow_id else "NULL"

    run_sql(f"""
        INSERT INTO telephony_phone_numbers 
          (organization_id, telephony_configuration_id, address, address_normalized, 
           address_type, country_code, label, inbound_workflow_id, is_active, 
           is_default_caller_id, extra_metadata, created_at, updated_at)
        VALUES 
          (1, 1, '{number}', '{number}', 
           'phone', 'IN', '{label}', {workflow_val}, true, 
           {'true' if make_default else 'false'},
           '{{}}', NOW(), NOW())
        ON CONFLICT (organization_id, address_normalized) DO UPDATE
          SET label              = EXCLUDED.label,
              inbound_workflow_id = EXCLUDED.inbound_workflow_id,
              is_default_caller_id = EXCLUDED.is_default_caller_id,
              is_active           = true,
              updated_at          = NOW();
    """, f"Adding/updating number {number} → '{label}'" + (f" (workflow {workflow_id})" if workflow_id else ""))

    print(f"\n✅ Done!")
    list_numbers()


if __name__ == "__main__":
    args = sys.argv[1:]

    if not args or "--list" in args:
        list_numbers()
        print()
        list_workflows()
        sys.exit(0)

    if len(args) < 2:
        print(__doc__)
        sys.exit(1)

    number = args[0]
    label  = args[1]

    workflow_id = None
    if "--workflow" in args:
        idx = args.index("--workflow")
        workflow_id = int(args[idx + 1])

    make_default = "--default" in args

    add_number(number, label, workflow_id, make_default)
