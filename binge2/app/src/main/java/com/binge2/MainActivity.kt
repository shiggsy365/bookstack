package com.binge2

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.binge2.data.database.AppDatabase
import com.binge2.data.repository.MovieRepository
import com.binge2.data.repository.TvRepository
import com.binge2.data.repository.UserDataRepository
import com.binge2.ui.components.Sidebar
import com.binge2.ui.navigation.Screen
import com.binge2.ui.screens.episodes.EpisodesScreen
import com.binge2.ui.screens.episodes.EpisodesViewModel
import com.binge2.ui.screens.movies.MoviesScreen
import com.binge2.ui.screens.movies.MoviesViewModel
import com.binge2.ui.screens.seasons.SeasonsScreen
import com.binge2.ui.screens.seasons.SeasonsViewModel
import com.binge2.ui.screens.shows.ShowsScreen
import com.binge2.ui.screens.shows.ShowsViewModel
import com.binge2.ui.screens.users.UserSelectionScreen
import com.binge2.ui.screens.users.UserSelectionViewModel
import com.binge2.ui.theme.BINGE2Theme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Initialize database and repositories
        val database = AppDatabase.getDatabase(applicationContext)
        val userDataRepository = UserDataRepository(database)
        val movieRepository = MovieRepository()
        val tvRepository = TvRepository()

        setContent {
            BINGE2Theme {
                BINGE2App(
                    userDataRepository = userDataRepository,
                    movieRepository = movieRepository,
                    tvRepository = tvRepository
                )
            }
        }
    }
}

@Composable
fun BINGE2App(
    userDataRepository: UserDataRepository,
    movieRepository: MovieRepository,
    tvRepository: TvRepository
) {
    val navController = rememberNavController()
    var currentUserId by remember { mutableStateOf<Long?>(null) }
    var sidebarVisible by remember { mutableStateOf(false) }
    var currentRoute by remember { mutableStateOf("user_selection") }

    // Update current route when navigation changes
    DisposableEffect(navController) {
        val listener = NavHostController.OnDestinationChangedListener { _, destination, _ ->
            currentRoute = destination.route ?: "user_selection"
        }
        navController.addOnDestinationChangedListener(listener)
        onDispose {
            navController.removeOnDestinationChangedListener(listener)
        }
    }

    // Handle back button to show sidebar
    BackHandler {
        sidebarVisible = !sidebarVisible
    }

    Box(modifier = Modifier.fillMaxSize()) {
        Row(modifier = Modifier.fillMaxSize()) {
            // Sidebar
            Sidebar(
                visible = sidebarVisible,
                onVisibilityChange = { sidebarVisible = it },
                currentRoute = currentRoute,
                onMenuItemClick = { route ->
                    navController.navigate(route) {
                        // Clear back stack if navigating to a top-level destination
                        if (route == "movies" || route == "shows" || route == "user_selection") {
                            popUpTo(navController.graph.startDestinationId) {
                                inclusive = true
                            }
                        }
                    }
                }
            )

            // Main content
            NavHost(
                navController = navController,
                startDestination = Screen.UserSelection.route,
                modifier = Modifier.fillMaxSize()
            ) {
                composable(Screen.UserSelection.route) {
                    UserSelectionScreen(
                        viewModel = UserSelectionViewModel(userDataRepository),
                        onUserSelected = { userId ->
                            currentUserId = userId
                            navController.navigate(Screen.Movies.route)
                        }
                    )
                }

                composable(Screen.Movies.route) {
                    val viewModel = remember {
                        MoviesViewModel(movieRepository, userDataRepository).apply {
                            currentUserId?.let { setCurrentUser(it) }
                        }
                    }
                    MoviesScreen(viewModel = viewModel)
                }

                composable(Screen.Shows.route) {
                    val viewModel = remember {
                        ShowsViewModel(tvRepository, userDataRepository).apply {
                            currentUserId?.let { setCurrentUser(it) }
                        }
                    }
                    ShowsScreen(
                        viewModel = viewModel,
                        onShowClick = { showId ->
                            navController.navigate(Screen.ShowSeasons.createRoute(showId))
                        }
                    )
                }

                composable(
                    route = Screen.ShowSeasons.route,
                    arguments = listOf(
                        navArgument("showId") { type = NavType.IntType }
                    )
                ) { backStackEntry ->
                    val showId = backStackEntry.arguments?.getInt("showId") ?: 0
                    val viewModel = remember(showId) {
                        SeasonsViewModel(tvRepository, showId)
                    }
                    SeasonsScreen(
                        showId = showId,
                        viewModel = viewModel,
                        onSeasonClick = { show, season ->
                            navController.navigate(Screen.ShowEpisodes.createRoute(show, season))
                        },
                        onBackClick = {
                            navController.popBackStack()
                        }
                    )
                }

                composable(
                    route = Screen.ShowEpisodes.route,
                    arguments = listOf(
                        navArgument("showId") { type = NavType.IntType },
                        navArgument("seasonNumber") { type = NavType.IntType }
                    )
                ) { backStackEntry ->
                    val showId = backStackEntry.arguments?.getInt("showId") ?: 0
                    val seasonNumber = backStackEntry.arguments?.getInt("seasonNumber") ?: 1
                    val viewModel = remember(showId, seasonNumber) {
                        EpisodesViewModel(tvRepository, userDataRepository, showId, seasonNumber)
                    }
                    EpisodesScreen(
                        showId = showId,
                        seasonNumber = seasonNumber,
                        viewModel = viewModel,
                        onBackClick = {
                            navController.popBackStack()
                        }
                    )
                }
            }
        }
    }
}
