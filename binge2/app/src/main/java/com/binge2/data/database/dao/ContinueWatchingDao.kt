package com.binge2.data.database.dao

import androidx.room.*
import com.binge2.data.database.entities.ContinueWatchingEntity
import kotlinx.coroutines.flow.Flow

@Dao
interface ContinueWatchingDao {
    @Query("SELECT * FROM continue_watching WHERE userId = :userId ORDER BY lastWatched DESC LIMIT 20")
    fun getContinueWatchingForUser(userId: Long): Flow<List<ContinueWatchingEntity>>

    @Query("SELECT * FROM continue_watching WHERE userId = :userId AND contentId = :contentId AND contentType = :contentType")
    suspend fun getContinueWatchingItem(userId: Long, contentId: Int, contentType: String): ContinueWatchingEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun updateProgress(item: ContinueWatchingEntity)

    @Query("DELETE FROM continue_watching WHERE userId = :userId AND contentId = :contentId")
    suspend fun removeFromContinueWatching(userId: Long, contentId: Int)

    @Query("DELETE FROM continue_watching WHERE userId = :userId AND (position * 100 / duration) >= 90")
    suspend fun cleanupFinishedItems(userId: Long)
}
