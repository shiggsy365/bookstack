package com.binge2.data.repository

import com.binge2.data.api.RetrofitClient
import com.binge2.data.models.Genre
import com.binge2.data.models.Season
import com.binge2.data.models.TvShow
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class TvRepository {
    private val api = RetrofitClient.tmdbApi

    suspend fun getTrendingTvShows(page: Int = 1): List<TvShow> = withContext(Dispatchers.IO) {
        try {
            api.getTrendingTvShows(page = page).results
        } catch (e: Exception) {
            emptyList()
        }
    }

    suspend fun getPopularTvShows(page: Int = 1): List<TvShow> = withContext(Dispatchers.IO) {
        try {
            api.getTrendingTvShows(page = page, sortBy = "popularity.desc").results
        } catch (e: Exception) {
            emptyList()
        }
    }

    suspend fun getTvShowsByGenre(genreId: Int, page: Int = 1): List<TvShow> = withContext(Dispatchers.IO) {
        try {
            api.getTvShowsByGenre(genreId = genreId, page = page).results
        } catch (e: Exception) {
            emptyList()
        }
    }

    suspend fun getTvShowDetails(tvId: Int): TvShow? = withContext(Dispatchers.IO) {
        try {
            api.getTvShowDetails(tvId)
        } catch (e: Exception) {
            null
        }
    }

    suspend fun getSeasonDetails(tvId: Int, seasonNumber: Int): Season? = withContext(Dispatchers.IO) {
        try {
            api.getSeasonDetails(tvId, seasonNumber)
        } catch (e: Exception) {
            null
        }
    }

    suspend fun getTvGenres(): List<Genre> = withContext(Dispatchers.IO) {
        try {
            api.getTvGenres().genres
        } catch (e: Exception) {
            emptyList()
        }
    }
}
