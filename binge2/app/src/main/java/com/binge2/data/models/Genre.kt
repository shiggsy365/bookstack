package com.binge2.data.models

data class Genre(
    val id: Int,
    val name: String
)

data class GenreResponse(
    val genres: List<Genre>
)
