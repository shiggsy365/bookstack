package com.binge2.data.models

import com.google.gson.annotations.SerializedName

data class Episode(
    val id: Int,
    val name: String,
    val overview: String,
    @SerializedName("episode_number")
    val episodeNumber: Int,
    @SerializedName("season_number")
    val seasonNumber: Int,
    @SerializedName("air_date")
    val airDate: String?,
    @SerializedName("still_path")
    val stillPath: String?,
    @SerializedName("vote_average")
    val voteAverage: Double,
    val runtime: Int?
) {
    fun getStillUrl(): String? = stillPath?.let { "https://image.tmdb.org/t/p/w500$it" }
}
