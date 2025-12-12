package com.binge2.data.repository

import com.binge2.data.database.AppDatabase
import com.binge2.data.database.entities.*
import kotlinx.coroutines.flow.Flow

class UserDataRepository(private val database: AppDatabase) {

    // User Management
    fun getAllUsers(): Flow<List<UserEntity>> = database.userDao().getAllUsers()

    suspend fun getUserById(userId: Long): UserEntity? = database.userDao().getUserById(userId)

    suspend fun createUser(name: String, avatarPath: String? = null): Long {
        return database.userDao().insertUser(UserEntity(name = name, avatarPath = avatarPath))
    }

    suspend fun deleteUser(user: UserEntity) = database.userDao().deleteUser(user)

    // Watchlist Management
    fun getMovieWatchlist(userId: Long): Flow<List<WatchlistEntity>> =
        database.watchlistDao().getWatchlistByType(userId, "movie")

    fun getTvWatchlist(userId: Long): Flow<List<WatchlistEntity>> =
        database.watchlistDao().getWatchlistByType(userId, "tv")

    suspend fun isInWatchlist(userId: Long, contentId: Int, contentType: String): Boolean =
        database.watchlistDao().isInWatchlist(userId, contentId, contentType)

    suspend fun addToWatchlist(userId: Long, contentId: Int, contentType: String, title: String, posterPath: String?) {
        database.watchlistDao().addToWatchlist(
            WatchlistEntity(
                userId = userId,
                contentId = contentId,
                contentType = contentType,
                title = title,
                posterPath = posterPath
            )
        )
    }

    suspend fun removeFromWatchlist(userId: Long, contentId: Int, contentType: String) {
        database.watchlistDao().removeFromWatchlist(userId, contentId, contentType)
    }

    // Watched Status Management
    suspend fun isMovieWatched(userId: Long, contentId: Int): Boolean =
        database.watchedDao().isMovieWatched(userId, contentId)

    suspend fun isEpisodeWatched(userId: Long, episodeId: Int): Boolean =
        database.watchedDao().isEpisodeWatched(userId, episodeId)

    suspend fun markMovieAsWatched(userId: Long, contentId: Int) {
        database.watchedDao().markAsWatched(
            WatchedEntity(
                userId = userId,
                contentId = contentId,
                contentType = "movie"
            )
        )
    }

    suspend fun markEpisodeAsWatched(userId: Long, showId: Int, episodeId: Int, seasonNumber: Int, episodeNumber: Int) {
        database.watchedDao().markAsWatched(
            WatchedEntity(
                userId = userId,
                contentId = showId,
                contentType = "episode",
                episodeId = episodeId,
                seasonNumber = seasonNumber,
                episodeNumber = episodeNumber
            )
        )
    }

    suspend fun markMovieAsUnwatched(userId: Long, contentId: Int) {
        database.watchedDao().markAsUnwatched(userId, contentId, "movie")
    }

    suspend fun markEpisodeAsUnwatched(userId: Long, episodeId: Int) {
        database.watchedDao().markEpisodeAsUnwatched(userId, episodeId)
    }

    // Continue Watching Management
    fun getContinueWatching(userId: Long): Flow<List<ContinueWatchingEntity>> =
        database.continueWatchingDao().getContinueWatchingForUser(userId)

    suspend fun updateProgress(
        userId: Long,
        contentId: Int,
        contentType: String,
        title: String,
        posterPath: String?,
        backdropPath: String?,
        position: Long,
        duration: Long,
        episodeId: Int? = null,
        seasonNumber: Int? = null,
        episodeNumber: Int? = null,
        episodeTitle: String? = null
    ) {
        database.continueWatchingDao().updateProgress(
            ContinueWatchingEntity(
                userId = userId,
                contentId = contentId,
                contentType = contentType,
                title = title,
                posterPath = posterPath,
                backdropPath = backdropPath,
                position = position,
                duration = duration,
                episodeId = episodeId,
                seasonNumber = seasonNumber,
                episodeNumber = episodeNumber,
                episodeTitle = episodeTitle
            )
        )
    }

    suspend fun removeFromContinueWatching(userId: Long, contentId: Int) {
        database.continueWatchingDao().removeFromContinueWatching(userId, contentId)
    }
}
