package com.binge2.ui.screens.users

import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.tv.foundation.lazy.grid.TvGridCells
import androidx.tv.foundation.lazy.grid.TvLazyVerticalGrid
import androidx.tv.foundation.lazy.grid.items
import androidx.tv.material3.Card
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import com.binge2.data.database.entities.UserEntity
import com.binge2.data.repository.UserDataRepository
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch

data class UserSelectionUiState(
    val users: List<UserEntity> = emptyList(),
    val isLoading: Boolean = false
)

class UserSelectionViewModel(
    private val userDataRepository: UserDataRepository
) : ViewModel() {

    private val _uiState = MutableStateFlow(UserSelectionUiState())
    val uiState: StateFlow<UserSelectionUiState> = _uiState.asStateFlow()

    init {
        loadUsers()
    }

    private fun loadUsers() {
        viewModelScope.launch {
            userDataRepository.getAllUsers().collect { users ->
                _uiState.update { it.copy(users = users) }
            }
        }
    }

    fun createUser(name: String) {
        viewModelScope.launch {
            userDataRepository.createUser(name)
        }
    }
}

@Composable
fun UserSelectionScreen(
    viewModel: UserSelectionViewModel,
    onUserSelected: (Long) -> Unit,
    modifier: Modifier = Modifier
) {
    val uiState by viewModel.uiState.collectAsState()

    Box(
        modifier = modifier.fillMaxSize(),
        contentAlignment = Alignment.Center
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(24.dp)
        ) {
            Text(
                text = "Who's watching?",
                style = MaterialTheme.typography.displayMedium
            )

            TvLazyVerticalGrid(
                columns = TvGridCells.Fixed(4),
                horizontalArrangement = Arrangement.spacedBy(16.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
                contentPadding = PaddingValues(48.dp)
            ) {
                items(uiState.users) { user ->
                    UserCard(
                        user = user,
                        onClick = { onUserSelected(user.id) }
                    )
                }

                // Add new user option
                item {
                    Card(
                        onClick = {
                            // Create a default user for now
                            viewModel.createUser("User ${uiState.users.size + 1}")
                        },
                        modifier = Modifier
                            .size(150.dp)
                    ) {
                        Box(
                            modifier = Modifier.fillMaxSize(),
                            contentAlignment = Alignment.Center
                        ) {
                            Text(
                                text = "+",
                                style = MaterialTheme.typography.displayLarge
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun UserCard(
    user: UserEntity,
    onClick: () -> Unit
) {
    Card(
        onClick = onClick,
        modifier = Modifier.size(150.dp)
    ) {
        Box(
            modifier = Modifier.fillMaxSize(),
            contentAlignment = Alignment.Center
        ) {
            Text(
                text = user.name.first().toString(),
                style = MaterialTheme.typography.displayLarge
            )
        }
    }
}
