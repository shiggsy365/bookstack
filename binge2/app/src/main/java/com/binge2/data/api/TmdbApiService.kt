package com.binge2.data.api

import com.binge2.data.models.*
import retrofit2.http.GET
import retrofit2.http.Path
import retrofit2.http.Query

interface TmdbApiService {

    // Movies
    @GET("discover/movie")
    suspend fun getTrendingMovies(
        @Query("include_adult") includeAdult: Boolean = false,
        @Query("include_video") includeVideo: Boolean = false,
        @Query("language") language: String = "en-US",
        @Query("page") page: Int = 1,
        @Query("region") region: String = "en-US",
        @Query("sort_by") sortBy: String = "popularity.desc",
        @Query("with_original_language") withOriginalLanguage: String = "en"
    ): MovieResponse

    @GET("discover/movie")
    suspend fun getMoviesByGenre(
        @Query("with_genres") genreId: Int,
        @Query("include_adult") includeAdult: Boolean = false,
        @Query("include_video") includeVideo: Boolean = false,
        @Query("language") language: String = "en-US",
        @Query("page") page: Int = 1,
        @Query("sort_by") sortBy: String = "popularity.desc",
        @Query("watch_region") watchRegion: String = "en-US",
        @Query("with_original_language") withOriginalLanguage: String = "en"
    ): MovieResponse

    @GET("movie/{movie_id}")
    suspend fun getMovieDetails(
        @Path("movie_id") movieId: Int,
        @Query("language") language: String = "en-US"
    ): Movie

    @GET("genre/movie/list")
    suspend fun getMovieGenres(
        @Query("language") language: String = "en"
    ): GenreResponse

    // TV Shows
    @GET("discover/tv")
    suspend fun getTrendingTvShows(
        @Query("include_adult") includeAdult: Boolean = false,
        @Query("include_null_first_air_dates") includeNull: Boolean = false,
        @Query("language") language: String = "en-US",
        @Query("page") page: Int = 1,
        @Query("sort_by") sortBy: String = "popularity.desc",
        @Query("watch_region") watchRegion: String = "en-US",
        @Query("with_original_language") withOriginalLanguage: String = "en"
    ): TvShowResponse

    @GET("discover/tv")
    suspend fun getTvShowsByGenre(
        @Query("with_genres") genreId: Int,
        @Query("include_adult") includeAdult: Boolean = false,
        @Query("include_null_first_air_dates") includeNull: Boolean = false,
        @Query("language") language: String = "en-US",
        @Query("page") page: Int = 1,
        @Query("sort_by") sortBy: String = "popularity.desc",
        @Query("watch_region") watchRegion: String = "en-US",
        @Query("with_original_language") withOriginalLanguage: String = "en"
    ): TvShowResponse

    @GET("tv/{tv_id}")
    suspend fun getTvShowDetails(
        @Path("tv_id") tvId: Int,
        @Query("language") language: String = "en-US"
    ): TvShow

    @GET("tv/{tv_id}/season/{season_number}")
    suspend fun getSeasonDetails(
        @Path("tv_id") tvId: Int,
        @Path("season_number") seasonNumber: Int,
        @Query("language") language: String = "en-US"
    ): Season

    @GET("genre/tv/list")
    suspend fun getTvGenres(
        @Query("language") language: String = "en"
    ): GenreResponse
}
