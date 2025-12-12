package com.binge2.data.models

import com.google.gson.annotations.SerializedName

data class Movie(
    val id: Int,
    val title: String,
    val overview: String,
    @SerializedName("poster_path")
    val posterPath: String?,
    @SerializedName("backdrop_path")
    val backdropPath: String?,
    @SerializedName("release_date")
    val releaseDate: String?,
    @SerializedName("vote_average")
    val voteAverage: Double,
    @SerializedName("genre_ids")
    val genreIds: List<Int>?,
    val genres: List<Genre>?
) {
    fun getPosterUrl(): String? = posterPath?.let { "https://image.tmdb.org/t/p/w500$it" }
    fun getBackdropUrl(): String? = backdropPath?.let { "https://image.tmdb.org/t/p/original$it" }
    fun getLogoUrl(): String? = backdropPath?.let { "https://image.tmdb.org/t/p/w300$it" }
}

data class MovieResponse(
    val page: Int,
    val results: List<Movie>,
    @SerializedName("total_pages")
    val totalPages: Int,
    @SerializedName("total_results")
    val totalResults: Int
)
