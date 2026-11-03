from motor.motor_asyncio import AsyncIOMotorClient, AsyncIOMotorDatabase
from app.config import settings
from loguru import logger
import certifi


client: AsyncIOMotorClient = None
database: AsyncIOMotorDatabase = None


async def connect_to_mongo():
    """Create database connection"""
    global client, database
    try:
        # For MongoDB Atlas, ensure SSL/TLS is properly configured
        # Motor automatically uses TLS for mongodb+srv:// connections
        # Use certifi's CA bundle to avoid SSL handshake errors on macOS
        client = AsyncIOMotorClient(
            settings.MONGO_URL,
            serverSelectionTimeoutMS=30000,  # 30 seconds timeout
            connectTimeoutMS=30000,
            socketTimeoutMS=30000,
            tlsCAFile=certifi.where(),
        )
        database = client[settings.DB_NAME]
        # Test connection
        await client.admin.command('ping')
        logger.info(f"✅ Connected to MongoDB: {settings.DB_NAME}")
    except Exception as e:
        logger.error(f"❌ Failed to connect to MongoDB: {str(e)}")
        raise

async def close_mongo_connection():
    """Close database connection"""
    global client
    if client:
        client.close()
        logger.info("✅ MongoDB connection closed")

def get_database() -> AsyncIOMotorDatabase:
    """Get database instance"""
    return database