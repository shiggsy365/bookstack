package com.binge2.ui.navigation

sealed class Screen(val route: String) {
    object UserSelection : Screen("user_selection")
    object Movies : Screen("movies")
    object Shows : Screen("shows")
    object ShowSeasons : Screen("show_seasons/{showId}") {
        fun createRoute(showId: Int) = "show_seasons/$showId"
    }
    object ShowEpisodes : Screen("show_episodes/{showId}/{seasonNumber}") {
        fun createRoute(showId: Int, seasonNumber: Int) = "show_episodes/$showId/$seasonNumber"
    }
}
