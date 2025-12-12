package com.binge2.data.database.dao

import androidx.room.*
import com.binge2.data.database.entities.WatchedEntity
import kotlinx.coroutines.flow.Flow

@Dao
interface WatchedDao {
    @Query("SELECT * FROM watched WHERE userId = :userId ORDER BY watchedAt DESC")
    fun getWatchedForUser(userId: Long): Flow<List<WatchedEntity>>

    @Query("SELECT EXISTS(SELECT 1 FROM watched WHERE userId = :userId AND contentId = :contentId AND contentType = 'movie')")
    suspend fun isMovieWatched(userId: Long, contentId: Int): Boolean

    @Query("SELECT EXISTS(SELECT 1 FROM watched WHERE userId = :userId AND episodeId = :episodeId)")
    suspend fun isEpisodeWatched(userId: Long, episodeId: Int): Boolean

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun markAsWatched(item: WatchedEntity)

    @Query("DELETE FROM watched WHERE userId = :userId AND contentId = :contentId AND contentType = :contentType")
    suspend fun markAsUnwatched(userId: Long, contentId: Int, contentType: String)

    @Query("DELETE FROM watched WHERE userId = :userId AND episodeId = :episodeId")
    suspend fun markEpisodeAsUnwatched(userId: Long, episodeId: Int)
}
