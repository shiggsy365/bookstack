package com.binge2.data.repository

import com.binge2.data.api.RetrofitClient
import com.binge2.data.models.Genre
import com.binge2.data.models.Movie
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class MovieRepository {
    private val api = RetrofitClient.tmdbApi

    suspend fun getTrendingMovies(page: Int = 1): List<Movie> = withContext(Dispatchers.IO) {
        try {
            api.getTrendingMovies(page = page).results
        } catch (e: Exception) {
            emptyList()
        }
    }

    suspend fun getPopularMovies(page: Int = 1): List<Movie> = withContext(Dispatchers.IO) {
        try {
            api.getTrendingMovies(page = page, sortBy = "popularity.desc").results
        } catch (e: Exception) {
            emptyList()
        }
    }

    suspend fun getMoviesByGenre(genreId: Int, page: Int = 1): List<Movie> = withContext(Dispatchers.IO) {
        try {
            api.getMoviesByGenre(genreId = genreId, page = page).results
        } catch (e: Exception) {
            emptyList()
        }
    }

    suspend fun getMovieDetails(movieId: Int): Movie? = withContext(Dispatchers.IO) {
        try {
            api.getMovieDetails(movieId)
        } catch (e: Exception) {
            null
        }
    }

    suspend fun getMovieGenres(): List<Genre> = withContext(Dispatchers.IO) {
        try {
            api.getMovieGenres().genres
        } catch (e: Exception) {
            emptyList()
        }
    }
}
