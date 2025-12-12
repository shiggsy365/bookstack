package com.binge2.data.database.entities

import androidx.room.Entity
import androidx.room.PrimaryKey

@Entity(tableName = "users")
data class UserEntity(
    @PrimaryKey(autoGenerate = true)
    val id: Long = 0,
    val name: String,
    val avatarPath: String? = null,
    val createdAt: Long = System.currentTimeMillis()
)
