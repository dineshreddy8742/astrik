import asyncio
import sys
from pathlib import Path

# Add project root to python path so we can import api modules
sys.path.append(str(Path(__file__).resolve().parent))

from api.db import db_client
from api.db.models import TelephonyConfigurationModel
from sqlalchemy import select, update

async def main():
    async with db_client.async_session() as session:
        result = await session.execute(select(TelephonyConfigurationModel))
        rows = result.scalars().all()
        print("Existing Telephony Configurations:")
        for row in rows:
            print(f"ID: {row.id}, Name: {row.name}, Provider: {row.provider}, Credentials: {row.credentials}")
            if row.provider == "ari":
                creds = dict(row.credentials or {})
                old_val = creds.get("ws_client_name")
                if old_val != "services.dograh.com:443":
                    creds["ws_client_name"] = "services.dograh.com:443"
                    await session.execute(
                        update(TelephonyConfigurationModel)
                        .where(TelephonyConfigurationModel.id == row.id)
                        .values(credentials=creds)
                    )
                    print(f"--> Updated configuration ID {row.id} ('{row.name}') to use 'services.dograh.com:443'")
        await session.commit()

if __name__ == "__main__":
    asyncio.run(main())
