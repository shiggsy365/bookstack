package com.binge2.data.database.entities

import androidx.room.Entity
import androidx.room.PrimaryKey

@Entity(tableName = "watchlist")
data class WatchlistEntity(
    @PrimaryKey(autoGenerate = true)
    val id: Long = 0,
    val userId: Long,
    val contentId: Int,
    val contentType: String, // "movie" or "tv"
    val title: String,
    val posterPath: String?,
    val addedAt: Long = System.currentTimeMillis()
)
