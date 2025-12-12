package com.binge2.data.database.dao

import androidx.room.*
import com.binge2.data.database.entities.WatchlistEntity
import kotlinx.coroutines.flow.Flow

@Dao
interface WatchlistDao {
    @Query("SELECT * FROM watchlist WHERE userId = :userId ORDER BY addedAt DESC")
    fun getWatchlistForUser(userId: Long): Flow<List<WatchlistEntity>>

    @Query("SELECT * FROM watchlist WHERE userId = :userId AND contentType = :contentType ORDER BY addedAt DESC")
    fun getWatchlistByType(userId: Long, contentType: String): Flow<List<WatchlistEntity>>

    @Query("SELECT EXISTS(SELECT 1 FROM watchlist WHERE userId = :userId AND contentId = :contentId AND contentType = :contentType)")
    suspend fun isInWatchlist(userId: Long, contentId: Int, contentType: String): Boolean

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun addToWatchlist(item: WatchlistEntity)

    @Query("DELETE FROM watchlist WHERE userId = :userId AND contentId = :contentId AND contentType = :contentType")
    suspend fun removeFromWatchlist(userId: Long, contentId: Int, contentType: String)
}
