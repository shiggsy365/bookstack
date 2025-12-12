package com.binge2.data.database

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import com.binge2.data.database.dao.*
import com.binge2.data.database.entities.*

@Database(
    entities = [
        UserEntity::class,
        WatchlistEntity::class,
        WatchedEntity::class,
        ContinueWatchingEntity::class
    ],
    version = 1,
    exportSchema = false
)
abstract class AppDatabase : RoomDatabase() {
    abstract fun userDao(): UserDao
    abstract fun watchlistDao(): WatchlistDao
    abstract fun watchedDao(): WatchedDao
    abstract fun continueWatchingDao(): ContinueWatchingDao

    companion object {
        @Volatile
        private var INSTANCE: AppDatabase? = null

        fun getDatabase(context: Context): AppDatabase {
            return INSTANCE ?: synchronized(this) {
                val instance = Room.databaseBuilder(
                    context.applicationContext,
                    AppDatabase::class.java,
                    "binge2_database"
                ).build()
                INSTANCE = instance
                instance
            }
        }
    }
}
