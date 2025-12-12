package com.binge2.data.database.entities

import androidx.room.Entity
import androidx.room.PrimaryKey

@Entity(tableName = "watched")
data class WatchedEntity(
    @PrimaryKey(autoGenerate = true)
    val id: Long = 0,
    val userId: Long,
    val contentId: Int,
    val contentType: String, // "movie" or "episode"
    val episodeId: Int? = null, // For TV episodes
    val seasonNumber: Int? = null,
    val episodeNumber: Int? = null,
    val watchedAt: Long = System.currentTimeMillis()
)
