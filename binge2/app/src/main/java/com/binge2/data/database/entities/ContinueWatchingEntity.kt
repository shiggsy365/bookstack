package com.binge2.data.database.entities

import androidx.room.Entity
import androidx.room.PrimaryKey

@Entity(tableName = "continue_watching")
data class ContinueWatchingEntity(
    @PrimaryKey(autoGenerate = true)
    val id: Long = 0,
    val userId: Long,
    val contentId: Int,
    val contentType: String, // "movie" or "episode"
    val title: String,
    val posterPath: String?,
    val backdropPath: String?,
    val episodeId: Int? = null,
    val seasonNumber: Int? = null,
    val episodeNumber: Int? = null,
    val episodeTitle: String? = null,
    val position: Long = 0, // Position in milliseconds
    val duration: Long = 0, // Total duration in milliseconds
    val lastWatched: Long = System.currentTimeMillis()
)
