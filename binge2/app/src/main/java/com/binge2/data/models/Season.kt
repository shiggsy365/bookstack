package com.binge2.data.models

import com.google.gson.annotations.SerializedName

data class Season(
    val id: Int,
    val name: String,
    val overview: String,
    @SerializedName("season_number")
    val seasonNumber: Int,
    @SerializedName("episode_count")
    val episodeCount: Int?,
    @SerializedName("air_date")
    val airDate: String?,
    @SerializedName("poster_path")
    val posterPath: String?,
    val episodes: List<Episode>?
) {
    fun getPosterUrl(): String? = posterPath?.let { "https://image.tmdb.org/t/p/w500$it" }
}
